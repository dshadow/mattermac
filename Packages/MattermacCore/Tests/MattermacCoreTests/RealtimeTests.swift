import Foundation
import Synchronization
import Testing

@testable import MattermacCore

private func postJSON(_ id: String = "post1", revision: Int = 10, deleted: Int = 0) -> String {
  """
  {"id":"\(id)","user_id":"other","channel_id":"channel1","root_id":"",
  "message":"revision \(revision)","create_at":1,"update_at":\(revision),"delete_at":\(deleted),"has_reactions":false}
  """
}

private func eventBytes(
  _ name: String, seq: Int = 0, data: [String: String] = [:], channel: String = "channel1"
) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "event": name, "seq": seq, "data": data, "broadcast": ["channel_id": channel],
  ])
}

private func page(_ json: [String]) throws -> ChannelPosts {
  let posts = try json.map { try JSONDecoder().decode(MattermostPost.self, from: Data($0.utf8)) }
  return ChannelPosts(
    order: posts.map(\.id), posts: Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) }))
}

private func channel() throws -> MattermostChannel {
  try JSONDecoder().decode(
    MattermostChannel.self,
    from: Data(
      #"{"id":"channel1","team_id":"team1","name":"test","display_name":"Test","type":"O"}"#.utf8))
}

private final class TestSocket: WebSocketConnection {
  struct State {
    var queued: [Data] = []
    var waiter: CheckedContinuation<Data, any Error>?
    var closed = false
    var sent: [Data] = []
  }
  let storage = Mutex(State())

  func push(_ data: Data) {
    let waiter = storage.withLock { state -> CheckedContinuation<Data, any Error>? in
      guard !state.closed else { return nil }
      if let waiter = state.waiter {
        state.waiter = nil
        return waiter
      }
      state.queued.append(data)
      return nil
    }
    waiter?.resume(returning: data)
  }

  func receive() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      storage.withLock { state in
        if state.closed {
          continuation.resume(throwing: WebSocketFailure.disconnected)
        } else if !state.queued.isEmpty {
          continuation.resume(returning: state.queued.removeFirst())
        } else {
          state.waiter = continuation
        }
      }
    }
  }

  func send(_ data: Data) async throws { storage.withLock { $0.sent.append(data) } }
  func ping() async throws {}
  func cancel() {
    let waiter = storage.withLock { state in
      state.closed = true
      let waiter = state.waiter
      state.waiter = nil
      return waiter
    }
    waiter?.resume(throwing: WebSocketFailure.disconnected)
  }
  var closed: Bool { storage.withLock { $0.closed } }
  var sent: [Data] { storage.withLock { $0.sent } }
}

private final class TestSocketTransport: WebSocketTransport {
  struct State {
    var sockets: [TestSocket]
    var requests: [URLRequest] = []
  }
  let storage: Mutex<State>
  init(_ sockets: [TestSocket]) { storage = Mutex(State(sockets: sockets)) }
  func connect(_ request: URLRequest) -> any WebSocketConnection {
    storage.withLock { state in
      state.requests.append(request)
      if !state.sockets.isEmpty { return state.sockets.removeFirst() }
      let socket = TestSocket()
      socket.cancel()
      return socket
    }
  }
  var requests: [URLRequest] { storage.withLock { $0.requests } }
}

private actor RealtimeHTTP: HTTPTransport {
  var posts = [postJSON()]
  var reactions: [String] = []
  var reactionRequests = 0
  var unauthorized = false
  var forbidden = false
  func setPosts(_ posts: [String]) { self.posts = posts }
  func setReactions(_ reactions: [String]) { self.reactions = reactions }
  func expire() { unauthorized = true }
  func deny() { forbidden = true }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let path = request.url!.path
    let json: String
    if path.hasSuffix("/users/me") {
      json = #"{"id":"user1","username":"tester"}"#
    } else if path.hasSuffix("/users/logout") {
      json = "{}"
    } else if path.hasSuffix("/teams") {
      json = #"[{"id":"team1","name":"test","display_name":"Test"}]"#
    } else if path.hasSuffix("/channels") {
      json =
        #"[{"id":"channel1","team_id":"team1","name":"test","display_name":"Test","type":"O"}]"#
    } else if path.hasSuffix("/reactions") {
      reactionRequests += 1
      json = "[" + reactions.joined(separator: ",") + "]"
    } else if path.hasSuffix("/posts") {
      let objects = try posts.map {
        try JSONDecoder().decode(MattermostPost.self, from: Data($0.utf8))
      }
      let entries = zip(objects, posts).map { "\"\($0.0.id)\":\($0.1)" }.joined(separator: ",")
      json = "{\"order\":[],\"posts\":{\(entries)}}"
    } else {
      throw APIError.invalidResponse
    }
    return HTTPResponse(
      data: Data(json.utf8),
      response: HTTPURLResponse(
        url: request.url!, statusCode: unauthorized ? 401 : (forbidden ? 403 : 200),
        httpVersion: nil, headerFields: nil
      )!)
  }
}

@MainActor private func eventually(_ condition: () -> Bool) async throws {
  for _ in 0..<200 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Condition did not become true within two seconds")
  throw WebSocketFailure.timedOut
}

private func realtimeCredential() throws -> SessionCredential {
  SessionCredential(
    server: try MattermostServer("https://example.com/chat"), userID: "user1",
    token: try SessionToken("syntheticSocketSecret"))
}

@MainActor private func realtime(
  sockets: TestSocketTransport, http: RealtimeHTTP,
  authentication: WebSocketAuthentication = .bearerHeader,
  storage: AccountPersistence? = nil
) -> RealtimeSession {
  RealtimeSession(
    storage: storage,
    transport: sockets, authentication: authentication,
    makeClient: { try MattermostAPIClient(server: $0, transport: http, log: { _ in }) },
    sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }, random: { 0.5 })
}

@Test @MainActor func realtimeCommitsSQLiteBeforePublishingAndRestoresCacheOffline() async throws {
  var root = URL(fileURLWithPath: #filePath)
  for _ in 0..<5 { root.deleteLastPathComponent() }
  root.appendPathComponent("tmp/realtime-persistence/\(UUID().uuidString)")
  let storage = AccountPersistence(root: root)
  let credential = try realtimeCredential()
  let account = SessionAccount(serverAddress: credential.serverAddress, userID: credential.userID)
  try await storage.reconcile(for: account)
  let socket = TestSocket()
  socket.push(try eventBytes("hello"))
  let session = realtime(
    sockets: TestSocketTransport([socket]), http: RealtimeHTTP(), storage: storage)
  session.start(credential: credential, unauthorized: {})
  try await eventually { session.state == .connected }
  let cache = try #require(storage.cache)
  #expect(try await cache.checkpoint(channelID: "channel1") == session.synchronization.checkpoint)
  socket.push(try eventBytes("post_edited", seq: 1, data: ["post": postJSON(revision: 20)]))
  try await eventually { session.synchronization.posts.first?.updateAt == 20 }
  #expect(try await cache.post(id: "post1")?.updateAt == 20)
  session.stop()
  let offline = RealtimeSession(
    storage: storage,
    makeClient: {
      try MattermostAPIClient(server: $0, transport: OfflineCacheHTTP(), log: { _ in })
    })
  offline.start(credential: credential, unauthorized: {})
  try await eventually { offline.state == .reconnecting }
  #expect(offline.synchronization.posts.first?.updateAt == 20)
  #expect(offline.synchronization.mentionPostIDs.isEmpty)
  offline.stop()
  try await storage.clear(for: account)
}

private struct OfflineCacheHTTP: HTTPTransport {
  func send(_ request: URLRequest) async throws -> HTTPResponse { throw APIError.offline }
}

@Test @MainActor func permissionInvalidationPurgesPersistedContentBeforeFailedRecovery()
  async throws
{
  var root = URL(fileURLWithPath: #filePath)
  for _ in 0..<5 { root.deleteLastPathComponent() }
  root.appendPathComponent("tmp/realtime-permissions/\(UUID().uuidString)")
  let storage = AccountPersistence(root: root)
  let credential = try realtimeCredential()
  let account = SessionAccount(serverAddress: credential.serverAddress, userID: credential.userID)
  try await storage.reconcile(for: account)
  let http = RealtimeHTTP()
  let socket = TestSocket()
  socket.push(try eventBytes("hello"))
  let session = realtime(sockets: TestSocketTransport([socket]), http: http, storage: storage)
  session.start(credential: credential, unauthorized: {})
  try await eventually { session.state == .connected }
  await http.deny()
  socket.push(try eventBytes("user_removed", seq: 1))
  try await eventually { session.state == .reconnecting }
  #expect(session.synchronization.posts.isEmpty)
  #expect(session.synchronization.channels.isEmpty)
  let cache = try #require(storage.cache)
  #expect(try await cache.post(id: "post1") == nil)
  session.stop()
  try await storage.clear(for: account)
}

@Test func websocketURLPreservesDeploymentSubpathAndRequiresTLS() throws {
  #expect(
    try MattermostServer("https://example.com/chat/").webSocketURL().absoluteString
      == "wss://example.com/chat/api/v4/websocket")
  #expect(throws: APIError.invalidServerURL) { try MattermostServer("http://example.com") }
  #expect(
    try MattermostServer("http://localhost:8065", allowInsecureLocalhost: true).webSocketURL()
      .scheme == "ws")
}

@Test func serverSequenceSeparatesRepliesDuplicatesAndGaps() throws {
  var sequence = WebSocketSequence()
  let hello = try WebSocketEvent.decode(eventBytes("hello"))
  #expect(try sequence.accept(hello))
  #expect(try !sequence.accept(hello))
  let reply = try WebSocketEvent.decode(Data(#"{"status":"OK","seq_reply":1}"#.utf8))
  #expect(try !sequence.accept(reply))
  #expect(throws: WebSocketFailure.sequenceGap) {
    try sequence.accept(WebSocketEvent.decode(eventBytes("future_unknown", seq: 2)))
  }
  #expect(try sequence.accept(WebSocketEvent.decode(eventBytes("future_unknown", seq: 1))))
}

@Test func backoffHasBoundedExponentialJitter() {
  let policy = WebSocketBackoff()
  #expect(policy.delay(attempt: 0, randomUnit: 0) == 0.5)
  #expect(policy.delay(attempt: 3, randomUnit: 1) == 8)
  #expect(policy.delay(attempt: 100, randomUnit: 1) == 30)
  #expect(policy.delay(attempt: 100, randomUnit: 0) == 15)
}

@Test @MainActor func importCannotUndoEditDeletionOrCrossWindowFence() throws {
  let sync = SynchronizationCoordinator()
  sync.setChannels([try channel()])
  let first = try #require(sync.beginImport())
  try sync.apply(
    WebSocketEvent.decode(eventBytes("post_edited", data: ["post": postJSON(revision: 20)])),
    origin: .live, userID: "user1")
  #expect(sync.commit(try page([postJSON()]), ticket: first))
  #expect(sync.posts.first?.updateAt == 20)
  let second = try #require(sync.beginImport())
  try sync.apply(
    WebSocketEvent.decode(
      eventBytes("post_deleted", data: ["post": postJSON(revision: 30, deleted: 30)])),
    origin: .live, userID: "user1")
  #expect(sync.commit(try page([postJSON(revision: 40)]), ticket: second))
  #expect(sync.posts.isEmpty)
  let stale = try #require(sync.beginImport())
  sync.reset()
  sync.setChannels([try channel()])
  #expect(!sync.commit(try page([postJSON()]), ticket: stale))
  #expect(sync.checkpoint == nil)
}

@Test @MainActor func authoritativeRecoveryRemovesMissedDeletesAndSuppressesMentions() throws {
  let sync = SynchronizationCoordinator()
  sync.setChannels([try channel()])
  let posted = try WebSocketEvent.decode(
    eventBytes("posted", data: ["post": postJSON(), "mentions": #"["user1"]"#]))
  try sync.apply(posted, origin: .recovery, userID: "user1")
  #expect(sync.mentionPostIDs.isEmpty)
  let ticket = try #require(sync.beginImport())
  sync.commit(try page([]), ticket: ticket)
  #expect(sync.posts.isEmpty)
  try sync.apply(posted, origin: .live, userID: "user1")
  try sync.apply(posted, origin: .live, userID: "user1")
  #expect(sync.posts.count == 1)
  #expect(sync.mentionPostIDs.isEmpty)
  let newPost = try WebSocketEvent.decode(
    eventBytes("posted", data: ["post": postJSON("post2"), "mentions": #"["user1"]"#]))
  try sync.apply(newPost, origin: .live, userID: "user1")
  try sync.apply(newPost, origin: .live, userID: "user1")
  #expect(sync.mentionPostIDs == ["post2"])
}

@Test @MainActor func routesPresenceTypingReactionsAndMetadata() throws {
  let sync = SynchronizationCoordinator()
  sync.setChannels([try channel()])
  try sync.apply(
    WebSocketEvent.decode(eventBytes("posted", data: ["post": postJSON()])), origin: .live,
    userID: "user1")
  try sync.apply(
    WebSocketEvent.decode(
      eventBytes("status_change", data: ["user_id": "other", "status": "online"])), origin: .live,
    userID: "user1")
  #expect(sync.statuses["other"] == "online")
  let now = Date()
  try sync.apply(
    WebSocketEvent.decode(eventBytes("typing", data: ["user_id": "other"])), origin: .live,
    userID: "user1", now: now)
  #expect(sync.typing.count == 1)
  sync.expireTyping(now: now.addingTimeInterval(9))
  #expect(sync.typing.isEmpty)
  let reaction = #"{"user_id":"other","post_id":"post1","emoji_name":"smile"}"#
  for name in ["reaction_added", "reaction_added", "reaction_removed"] {
    try sync.apply(
      WebSocketEvent.decode(eventBytes(name, data: ["reaction": reaction])), origin: .live,
      userID: "user1")
  }
  #expect(sync.reactionChanges.values.first == false)
  #expect(
    try sync.apply(
      WebSocketEvent.decode(eventBytes("channel_updated")), origin: .live, userID: "user1"))
  #expect(throws: WebSocketFailure.malformedMessage) {
    try sync.apply(
      WebSocketEvent.decode(eventBytes("posted", data: ["post": "broken"])), origin: .live,
      userID: "user1")
  }
}

@Test @MainActor func oneSocketPerSessionAndCleanShutdown() async throws {
  let socket = TestSocket()
  socket.push(try eventBytes("hello"))
  let transport = TestSocketTransport([socket])
  let session = realtime(sockets: transport, http: RealtimeHTTP())
  defer { session.stop() }
  let credential = try realtimeCredential()
  session.start(credential: credential, unauthorized: {})
  try await eventually { session.state == .connected }
  session.start(credential: credential, unauthorized: {})
  #expect(transport.requests.count == 1)
  #expect(transport.requests.first?.url?.path == "/chat/api/v4/websocket")
  #expect(
    transport.requests.first?.value(forHTTPHeaderField: "Authorization")
      == "Bearer syntheticSocketSecret")
  #expect(session.synchronization.posts.count == 1)
  socket.push(try eventBytes("post_edited", seq: 1, data: ["post": postJSON(revision: 20)]))
  try await eventually { session.synchronization.posts.first?.updateAt == 20 }
  socket.push(
    try eventBytes("post_deleted", seq: 2, data: ["post": postJSON(revision: 30, deleted: 30)]))
  try await eventually { session.synchronization.posts.isEmpty }
  session.stop()
  #expect(socket.closed)
  #expect(session.state == .stopped)
  #expect(session.synchronization.channels.isEmpty)
}

@Test @MainActor func localRealtimeUsesOptedInHTTPAndWebSocket() async throws {
  let socket = TestSocket()
  socket.push(try eventBytes("hello"))
  let transport = TestSocketTransport([socket])
  let http = RealtimeHTTP()
  let session = RealtimeSession(
    transport: transport, allowInsecureLocalhost: true,
    makeClient: { try MattermostAPIClient(server: $0, transport: http, log: { _ in }) })
  defer { session.stop() }
  session.start(
    credential: SessionCredential(
      server: try MattermostServer("http://127.0.0.1:8065", allowInsecureLocalhost: true),
      userID: "user1", token: try SessionToken("syntheticSocketSecret")), unauthorized: {})
  try await eventually { session.state == .connected }
  #expect(transport.requests.first?.url?.absoluteString == "ws://127.0.0.1:8065/api/v4/websocket")
}

@Test @MainActor func sequenceGapReconnectsAndRebuildsWindowWithoutDuplicates() async throws {
  let first = TestSocket()
  let second = TestSocket()
  first.push(try eventBytes("hello"))
  second.push(try eventBytes("hello"))
  let http = RealtimeHTTP()
  let transport = TestSocketTransport([first, second])
  let session = realtime(sockets: transport, http: http)
  defer { session.stop() }
  session.start(credential: try realtimeCredential(), unauthorized: {})
  try await eventually { session.state == .connected }
  await http.setPosts([postJSON("post2", revision: 50)])
  first.push(try eventBytes("posted", seq: 3, data: ["post": postJSON("missed")]))
  try await eventually { transport.requests.count == 2 && session.state == .connected }
  #expect(first.closed)
  #expect(session.synchronization.posts.map(\.id) == ["post2"])
  #expect(session.synchronization.mentionPostIDs.isEmpty)
}

@Test @MainActor func challengeAuthenticatesAndRejectedChallengeExpires() async throws {
  let socket = TestSocket()
  socket.push(try eventBytes("hello"))
  socket.push(try eventBytes("future_plugin", seq: 1))
  socket.push(Data(#"{"status":"OK","seq_reply":1}"#.utf8))
  let transport = TestSocketTransport([socket])
  let session = realtime(sockets: transport, http: RealtimeHTTP(), authentication: .challenge)
  session.start(credential: try realtimeCredential(), unauthorized: {})
  try await eventually { session.state == .connected }
  #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
  let sent = try #require(socket.sent.first)
  let challenge = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
  #expect(challenge["action"] as? String == "authentication_challenge")
  #expect((challenge["data"] as? [String: String])?["token"] == "syntheticSocketSecret")
  session.stop()

  let rejected = TestSocket()
  rejected.push(Data(#"{"status":"FAIL","seq_reply":1}"#.utf8))
  let failed = realtime(
    sockets: TestSocketTransport([rejected]), http: RealtimeHTTP(), authentication: .challenge)
  defer { failed.stop() }
  var expired = false
  failed.start(credential: try realtimeCredential(), unauthorized: { expired = true })
  try await eventually { expired }
  #expect(rejected.closed)
  #expect(failed.state == .stopped)
}

@Test @MainActor func sleepNetworkAndExpiredRESTStopSocketWork() async throws {
  let first = TestSocket()
  let second = TestSocket()
  first.push(try eventBytes("hello"))
  second.push(try eventBytes("hello"))
  let http = RealtimeHTTP()
  let transport = TestSocketTransport([first, second])
  let session = realtime(sockets: transport, http: http)
  defer { session.stop() }
  var expired = false
  session.start(credential: try realtimeCredential(), unauthorized: { expired = true })
  try await eventually { session.state == .connected }
  session.suspend()
  #expect(first.closed)
  session.networkChanged(available: false)
  session.resume()
  #expect(session.state == .suspended)
  #expect(transport.requests.count == 1)
  session.networkChanged(available: true)
  try await eventually { session.state == .connected }
  await http.expire()
  session.networkChanged(available: true)
  try await eventually { expired }
  #expect(second.closed)
  #expect(transport.requests.count == 2)
}

@Test func socketDeadlineCancelsSuspendedReceive() async throws {
  let socket = TestSocket()
  await #expect(throws: (any Error).self) {
    try await withSocketDeadline(socket, seconds: 0.01) { try await socket.receive() }
  }
  #expect(socket.closed)
}

private actor DelayedIdentityHTTP: HTTPTransport {
  let fallback = RealtimeHTTP()
  var first = true
  var entered = false
  var entryWaiter: CheckedContinuation<Void, Never>?
  var releaseWaiter: CheckedContinuation<Void, Never>?

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if !first { return try await fallback.send(request) }
    first = false
    entered = true
    entryWaiter?.resume()
    entryWaiter = nil
    await withCheckedContinuation { releaseWaiter = $0 }
    return HTTPResponse(
      data: Data(),
      response: HTTPURLResponse(
        url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
  }

  func waitForEntry() async {
    if entered { return }
    await withCheckedContinuation { entryWaiter = $0 }
  }

  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

@Test @MainActor func oldUnauthorizedCallbackCannotExpireReplacementSession() async throws {
  let http = DelayedIdentityHTTP()
  let socket = TestSocket()
  socket.push(try eventBytes("hello"))
  let transport = TestSocketTransport([socket])
  let session = RealtimeSession(
    transport: transport,
    makeClient: {
      try MattermostAPIClient(server: $0, transport: http, log: { _ in })
    })
  defer { session.stop() }
  var oldExpired = false
  var newExpired = false
  session.start(credential: try realtimeCredential(), unauthorized: { oldExpired = true })
  await http.waitForEntry()
  session.stop()
  session.start(credential: try realtimeCredential(), unauthorized: { newExpired = true })
  try await eventually { session.state == .connected }
  await http.release()
  // Let the old task resume; its generation fence must reject the late 401.
  await Task.yield()
  #expect(!oldExpired && !newExpired)
  #expect(session.state == .connected)
  #expect(transport.requests.count == 1)
}

@MainActor private final class RealtimeCredentialStore: SessionCredentialStore {
  var credential: SessionCredential?
  func load() throws -> SessionCredential? { credential }
  func save(_ credential: SessionCredential) throws { self.credential = credential }
  func delete() throws { credential = nil }
}

@Test @MainActor func authenticationOwnsSocketExpirationAndLogout() async throws {
  let first = TestSocket()
  let second = TestSocket()
  first.push(try eventBytes("hello"))
  second.push(try eventBytes("hello"))
  let http = RealtimeHTTP()
  let transport = TestSocketTransport([first, second])
  let live = realtime(sockets: transport, http: http)
  defer { live.stop() }
  let store = RealtimeCredentialStore()
  store.credential = try realtimeCredential()
  let auth = AuthenticationSession(
    store: store, realtime: live,
    makeClient: {
      try MattermostAPIClient(server: $0, transport: http, log: { _ in })
    })
  await auth.restore()
  try await eventually { live.state == .connected }
  await http.expire()
  live.networkChanged(available: true)
  try await eventually { auth.phase == .reauthenticationRequired }
  #expect(first.closed)
  #expect(live.synchronization.posts.isEmpty)
  #expect(store.credential != nil)
  await auth.logout()
  #expect(auth.phase == .signedOut)
  #expect(store.credential == nil)
  #expect(live.state == .stopped)
}

@Test func unknownPayloadIsDiscardedAndFrameSizeIsBounded() throws {
  let event = try WebSocketEvent.decode(
    Data(#"{"event":"plugin_future","seq":0,"data":{"post":{},"status":true}}"#.utf8))
  #expect(event.event == "plugin_future")
  #expect(event.data == nil)
  #expect(throws: WebSocketFailure.capacityExceeded) {
    try WebSocketEvent.decode(Data(repeating: 0, count: 1_048_577))
  }
}

@Test @MainActor func reconnectRecoversMissedReactionRemoval() async throws {
  let first = TestSocket()
  let second = TestSocket()
  first.push(try eventBytes("hello"))
  second.push(try eventBytes("hello"))
  let http = RealtimeHTTP()
  await http.setPosts([postJSON().replacingOccurrences(of: "false", with: "true")])
  await http.setReactions([#"{"post_id":"post1","user_id":"other","emoji_name":"smile"}"#])
  let session = realtime(sockets: TestSocketTransport([first, second]), http: http)
  defer { session.stop() }
  session.start(credential: try realtimeCredential(), unauthorized: {})
  try await eventually { session.state == .connected }
  #expect(session.synchronization.reactions.count == 1)
  await http.setReactions([])
  session.networkChanged(available: true)
  try await eventually { session.state == .connected }
  #expect(session.synchronization.reactions.isEmpty)
  #expect(await http.reactionRequests == 2)
}

@Test @MainActor func restReactionBaselineCannotUndoConcurrentSocketRemoval() throws {
  let sync = SynchronizationCoordinator()
  sync.setChannels([try channel()])
  let initial = try #require(sync.beginImport())
  let posts = try page([postJSON()])
  sync.commit(posts, ticket: initial)
  let reactionJSON = #"{"post_id":"post1","user_id":"other","emoji_name":"smile"}"#
  let reaction = try JSONDecoder().decode(MattermostReaction.self, from: Data(reactionJSON.utf8))
  let ticket = try #require(sync.beginImport())
  try sync.apply(
    WebSocketEvent.decode(eventBytes("reaction_removed", data: ["reaction": reactionJSON])),
    origin: .recovery, userID: "user1")
  sync.commit(posts, reactions: [reaction], ticket: ticket)
  #expect(sync.reactions.isEmpty)
}

@Test @MainActor func restDeletionCannotBeResurrectedByDelayedSocketPost() throws {
  let sync = SynchronizationCoordinator()
  sync.setChannels([try channel()])
  let ticket = try #require(sync.beginImport())
  sync.commit(try page([postJSON(deleted: 30)]), ticket: ticket)
  try sync.apply(
    WebSocketEvent.decode(
      eventBytes("posted", data: ["post": postJSON(), "mentions": #"["user1"]"#])), origin: .live,
    userID: "user1")
  #expect(sync.posts.isEmpty)
  #expect(sync.mentionPostIDs.isEmpty)
}
