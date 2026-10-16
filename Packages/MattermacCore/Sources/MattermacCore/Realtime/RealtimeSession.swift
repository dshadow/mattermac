import Foundation
import Observation

public enum RealtimeConnectionState: String, Sendable {
  case stopped = "Disconnected"
  case connecting = "Connecting…"
  case synchronizing = "Recovering recent messages…"
  case connected = "Live"
  case reconnecting = "Connection lost. Reconnecting…"
  case suspended = "Waiting for network or wake…"
}

private struct AuthenticatedSocket: Sendable {
  let sequence: WebSocketSequence
  let pending: [WebSocketEvent]
}

/// One app-owned connection, shared by all windows. All callbacks/imports carry a run fence.
@MainActor @Observable public final class RealtimeSession {
  public private(set) var state: RealtimeConnectionState = .stopped
  public let synchronization = SynchronizationCoordinator()

  private let transport: any WebSocketTransport
  private let authentication: WebSocketAuthentication
  private let allowInsecureLocalhost: Bool
  private let makeClient: @Sendable (MattermostServer) throws -> MattermostAPIClient
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let random: @Sendable () -> Double
  private var credential: SessionCredential?
  private var unauthorized: (@MainActor () -> Void)?
  private var worker: Task<Void, Never>?
  private var socket: (any WebSocketConnection)?
  private var runID = UUID()
  private var sleeping = false
  private var networkAvailable = true

  public init(
    transport: any WebSocketTransport = URLSessionWebSocketTransport(),
    authentication: WebSocketAuthentication = .bearerHeader,
    allowInsecureLocalhost: Bool = false,
    makeClient: @escaping @Sendable (MattermostServer) throws -> MattermostAPIClient = {
      try MattermostAPIClient(server: $0)
    },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    },
    random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    self.transport = transport
    self.authentication = authentication
    self.allowInsecureLocalhost = allowInsecureLocalhost
    self.makeClient = makeClient
    self.sleep = sleep
    self.random = random
  }

  public func start(
    credential: SessionCredential, unauthorized: @escaping @MainActor () -> Void
  ) {
    if self.credential == credential, worker != nil { return }
    stop()
    self.credential = credential
    self.unauthorized = unauthorized
    restart()
  }

  public func stop() {
    cancelRun()
    credential = nil
    unauthorized = nil
    synchronization.reset()
    state = .stopped
  }

  public func selectChannel(_ id: String) {
    guard synchronization.channels.contains(where: { $0.id == id }),
      synchronization.selectedChannelID != id
    else { return }
    synchronization.selectChannel(id)
    restart()
  }

  public func suspend() {
    sleeping = true
    restart()
  }

  public func resume() {
    sleeping = false
    restart()
  }

  /// Call for both reachability and interface changes; no online polling while offline.
  public func networkChanged(available: Bool) {
    networkAvailable = available
    restart()
  }

  private func cancelRun() {
    runID = UUID()
    worker?.cancel()
    worker = nil
    socket?.cancel()
    socket = nil
  }

  private func restart() {
    cancelRun()
    guard let credential else { return }
    guard !sleeping, networkAvailable else {
      state = .suspended
      return
    }
    let current = runID
    state = .connecting
    worker = Task { [weak self] in
      await self?.run(credential, current: current)
    }
  }

  private func isCurrent(_ current: UUID) -> Bool {
    current == runID && !Task.isCancelled
  }

  private func run(_ credential: SessionCredential, current: UUID) async {
    var failures = 0
    while isCurrent(current) {
      let connectedAt = Date()
      do {
        let server = try MattermostServer(
          credential.serverAddress, allowInsecureLocalhost: allowInsecureLocalhost)
        let client = try makeClient(server)
        // A close frame need not explain token expiry. REST verifies identity before each dial.
        let user = try await client.currentUser(token: credential.token)
        guard isCurrent(current) else { return }
        guard user.id == credential.userID else { throw APIError.unauthorized }
        var request = URLRequest(url: try server.webSocketURL(), timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        if authentication == .bearerHeader {
          request.setValue(
            "Bearer " + (try credential.token.value), forHTTPHeaderField: "Authorization")
        }
        let connection = transport.connect(request)
        socket = connection
        try await withTaskCancellationHandler {
          try await connected(connection, credential: credential, client: client, current: current)
        } onCancel: {
          connection.cancel()
        }
      } catch {
        guard isCurrent(current) else { return }
        socket?.cancel()
        socket = nil
        if error as? APIError == .unauthorized {
          let callback = unauthorized
          stop()
          callback?()
          return
        }
        if error as? WebSocketFailure == .capacityExceeded { synchronization.resetWindow() }
        // Reset backoff only after a stable connection, never on a short-lived hello.
        if Date().timeIntervalSince(connectedAt) >= 60 { failures = 0 }
        state = .reconnecting
        let delay = WebSocketBackoff().delay(attempt: failures, randomUnit: random())
        failures = min(failures + 1, 5)
        do { try await sleep(delay) } catch { return }
      }
    }
  }

  private func connected(
    _ connection: any WebSocketConnection, credential: SessionCredential,
    client: MattermostAPIClient, current: UUID
  ) async throws {
    let authentication = authentication
    let handshake = try await withSocketDeadline(connection, seconds: 15) {
      if authentication == .challenge {
        let challenge = AuthenticationChallenge(
          data: .init(token: try credential.token.value))
        try await connection.send(JSONEncoder().encode(challenge))
      }
      var sequence = WebSocketSequence()
      var pending: [WebSocketEvent] = []
      var hello = false
      var authenticated = authentication == .bearerHeader
      while !hello || !authenticated {
        let event = try WebSocketEvent.decode(await connection.receive())
        if event.replySequence == 1 {
          guard event.status == "OK" else { throw APIError.unauthorized }
          authenticated = true
        } else if try sequence.accept(event) {
          if !hello {
            guard event.event == "hello" else { throw WebSocketFailure.malformedMessage }
            hello = true
          } else {
            guard pending.count < 200 else { throw WebSocketFailure.capacityExceeded }
            pending.append(event)
          }
        }
      }
      return AuthenticatedSocket(sequence: sequence, pending: pending)
    }
    guard isCurrent(current) else { throw CancellationError() }
    state = .synchronizing
    synchronization.beginRecovery()
    for event in handshake.pending {
      try synchronization.apply(event, origin: .recovery, userID: credential.userID)
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await self.readEvents(
          connection, sequence: handshake.sequence, userID: credential.userID, current: current)
      }
      group.addTask {
        try await self.reconcile(client: client, credential: credential, current: current)
      }
      group.addTask {
        try await self.heartbeat(connection, current: current)
      }
      defer {
        group.cancelAll()
        connection.cancel()
      }
      while try await group.next() != nil {}
    }
  }

  private func readEvents(
    _ connection: any WebSocketConnection, sequence initial: WebSocketSequence,
    userID: String, current: UUID
  ) async throws {
    var sequence = initial
    while !Task.isCancelled {
      let event = try WebSocketEvent.decode(await connection.receive())
      guard isCurrent(current) else { return }
      guard try sequence.accept(event) else { continue }
      if event.event == "hello" { throw WebSocketFailure.sequenceGap }
      let refresh = try synchronization.apply(
        event, origin: state == .connected ? .live : .recovery, userID: userID)
      if refresh { throw WebSocketFailure.sequenceGap }
    }
  }

  private func heartbeat(_ connection: any WebSocketConnection, current: UUID) async throws {
    var ticks = 0
    while !Task.isCancelled {
      try await Task.sleep(for: .seconds(5))
      guard isCurrent(current) else { return }
      synchronization.expireTyping()
      ticks += 1
      if ticks % 4 == 0 {
        try await withSocketDeadline(connection, seconds: 10) { try await connection.ping() }
      }
    }
  }

  private func reconcile(
    client: MattermostAPIClient, credential: SessionCredential, current: UUID
  ) async throws {
    let token = try credential.token
    let teams = try await client.teams(token: token)
    var channels: [String: MattermostChannel] = [:]
    for team in teams {
      for channel in try await client.channels(teamID: team.id, token: token) {
        channels[channel.id] = channel
        guard channels.count <= 10_000 else { throw WebSocketFailure.capacityExceeded }
      }
      guard isCurrent(current) else { throw CancellationError() }
    }
    guard isCurrent(current) else { throw CancellationError() }
    synchronization.setChannels(Array(channels.values))
    if let ticket = synchronization.beginImport() {
      let page = try await client.channelPosts(
        channelID: ticket.channelID, page: PostPage(size: 200), token: token)
      let reactions = try await recoverReactions(page, client: client, token: token)
      guard isCurrent(current), synchronization.commit(page, reactions: reactions, ticket: ticket)
      else {
        throw CancellationError()
      }
    }
    guard isCurrent(current) else { throw CancellationError() }
    state = .connected
  }

  private func recoverReactions(
    _ page: ChannelPosts, client: MattermostAPIClient, token: SessionToken
  ) async throws -> [MattermostReaction] {
    // Mattermost 11.7/11.9 omit has_reactions when false. Fetch only flagged posts.
    let ids = page.posts.values.filter { $0.deleteAt == 0 && $0.hasReactions == true }.map(\.id)
    return try await withThrowingTaskGroup(of: [MattermostReaction].self) { group in
      var iterator = ids.makeIterator()
      for _ in 0..<min(4, ids.count) {
        if let id = iterator.next() {
          group.addTask { try await client.postReactions(postID: id, token: token) }
        }
      }
      var reactions: [MattermostReaction] = []
      while let batch = try await group.next() {
        reactions.append(contentsOf: batch)
        guard reactions.count <= 2_000 else { throw WebSocketFailure.capacityExceeded }
        if let id = iterator.next() {
          group.addTask { try await client.postReactions(postID: id, token: token) }
        }
      }
      return reactions
    }
  }
}
