import Foundation
import Synchronization
import Testing

@testable import MattermacCore

private let userJSON = #"{"id":"user1","username":"tester","unneeded":"ignored"}"#
private let postJSON =
  #"{"id":"post1","user_id":"user1","channel_id":"channel1","root_id":"","message":"Synthetic post","create_at":1700000000123,"update_at":1700000000123,"delete_at":0}"#

private actor ScriptedTransport: HTTPTransport {
  enum Step: Sendable {
    case response(Int, String, [String: String] = [:])
    case failure(URLError.Code)
    case suspend
  }

  private var steps: [Step]
  private(set) var requests: [URLRequest] = []

  init(_ steps: [Step]) { self.steps = steps }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !steps.isEmpty else { throw APIError.transportFailed }
    switch steps.removeFirst() {
    case .response(let status, let json, let headers):
      return HTTPResponse(
        data: Data(json.utf8),
        response: HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    case .failure(let code): throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "secret"])
    case .suspend:
      try await Task.sleep(for: .seconds(60))
      throw APIError.transportFailed
    }
  }
}

private actor Delays {
  private(set) var values: [TimeInterval] = []
  func append(_ value: TimeInterval) { values.append(value) }
}

private func client(
  _ transport: ScriptedTransport,
  policy: APIRetryPolicy = .standard,
  sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
  log: @escaping @Sendable (APIRequestEvent) -> Void = { _ in }
) throws -> MattermostAPIClient {
  try MattermostAPIClient(
    server: MattermostServer("https://example.com/mattermost/"), transport: transport,
    requestTimeout: 12, retryPolicy: policy, sleep: sleep, log: log)
}

@Test func loginEncodesMFAAndReadsCaseInsensitiveHeader() async throws {
  let transport = ScriptedTransport([.response(200, userJSON, ["tOkEn": "syntheticToken"])])
  let session = try await client(transport).login(
    LoginCredentials(
      loginID: "tester@example.com", password: "syntheticPassword", mfaCode: "001234"))
  #expect(session.user.id == "user1")
  #expect(session.user.mfaActive == nil)
  #expect(session.token.value == "syntheticToken")
  let request = try #require(await transport.requests.first)
  #expect(request.url?.absoluteString == "https://example.com/mattermost/api/v4/users/login")
  #expect(request.httpMethod == "POST")
  #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
  #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
  #expect(request.timeoutInterval == 12)
  #expect(!request.httpShouldHandleCookies)
  #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
  let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
  #expect(
    body == ["login_id": "tester@example.com", "password": "syntheticPassword", "token": "001234"])
}

@Test func passwordOnlyLoginOmitsMFA() async throws {
  let transport = ScriptedTransport([.response(200, userJSON, ["Token": "syntheticToken"])])
  _ = try await client(transport).login(LoginCredentials(loginID: "tester", password: "synthetic"))
  let request = try #require(await transport.requests.first)
  let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
  #expect(body?["token"] == nil)
}

@Test func initialReadEndpointsAndLogoutWorkWithoutUI() async throws {
  let transport = ScriptedTransport([
    .response(200, userJSON),
    .response(200, #"[{"id":"team1","name":"test","display_name":"Test"}]"#),
    .response(
      200,
      #"[{"id":"channel1","team_id":"team1","name":"test","display_name":"Test","type":"future"}]"#),
    .response(200, "{\"order\":[\"post1\"],\"posts\":{\"post1\":\(postJSON)}}"),
    .response(200, #"{"status":"OK"}"#),
  ])
  let api = try client(transport)
  let token = try SessionToken("syntheticToken")
  #expect(try await api.currentUser(token: token).username == "tester")
  #expect(try await api.teams(token: token).first?.displayName == "Test")
  #expect(try await api.channels(teamID: "team1", token: token).first?.type == "future")
  let posts = try await api.channelPosts(
    channelID: "channel1", page: PostPage(number: 2, size: 25), token: token)
  #expect(posts.orderedPosts.map(\.id) == ["post1"])
  #expect(posts.posts["post1"]?.createAt == 1_700_000_000_123)
  try await api.logout(token: token)
  let requests = await transport.requests
  #expect(
    requests.map { $0.url!.path } == [
      "/mattermost/api/v4/users/me", "/mattermost/api/v4/users/me/teams",
      "/mattermost/api/v4/users/me/teams/team1/channels",
      "/mattermost/api/v4/channels/channel1/posts", "/mattermost/api/v4/users/logout",
    ])
  #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "GET", "POST"])
  #expect(
    requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer syntheticToken" }
  )
  #expect(requests[3].url?.query == "page=2&per_page=25")
}

@Test func postCreationEncodesOnlyWritableFields() async throws {
  let transport = ScriptedTransport([.response(201, postJSON)])
  let post = try await client(transport).createPost(
    CreatePost(channelID: "channel1", message: "Synthetic post", rootID: "root1"),
    token: SessionToken("syntheticToken"))
  #expect(post.id == "post1")
  let request = try #require(await transport.requests.first)
  #expect(request.httpMethod == "POST")
  #expect(request.url?.path == "/mattermost/api/v4/posts")
  let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
  #expect(body == ["channel_id": "channel1", "message": "Synthetic post", "root_id": "root1"])
}

@Test(arguments: [301, 304, 400, 401, 403, 404, 429, 500, 503])
func statusFailuresAreTypedAndSanitized(status: Int) async throws {
  let transport = ScriptedTransport([
    .response(status, #"{"message":"secret","detailed_error":"private"}"#)
  ])
  let api = try client(transport, policy: APIRetryPolicy(maximumAttempts: 1))
  let expected: APIError
  switch status {
  case 401: expected = .unauthorized
  case 403: expected = .forbidden
  case 429: expected = .rateLimited(retryAfter: nil)
  default: expected = .http(status: status, retryAfter: nil)
  }
  await #expect(throws: expected) {
    try await api.currentUser(token: SessionToken("syntheticToken"))
  }
  #expect(await transport.requests.count == 1)
}

@Test func malformedSuccessAndMissingTokenAreTyped() async throws {
  let transport = ScriptedTransport([
    .response(200, "not JSON"), .response(200, userJSON),
    .response(200, userJSON, ["Token": "bad token"]),
  ])
  let api = try client(transport)
  await #expect(throws: APIError.decodingFailed) {
    try await api.currentUser(token: SessionToken("syntheticToken"))
  }
  let credentials = try LoginCredentials(loginID: "tester", password: "synthetic")
  await #expect(throws: APIError.missingSessionToken) { try await api.login(credentials) }
  await #expect(throws: APIError.invalidCredentials) { try await api.login(credentials) }
  #expect(await transport.requests.count == 3)
}

@Test func safeReadsRetryWithBoundedBackoff() async throws {
  let transport = ScriptedTransport([
    .failure(.networkConnectionLost), .response(503, ""), .response(200, userJSON),
  ])
  let delays = Delays()
  let api = try client(transport, sleep: { await delays.append($0) })
  #expect(try await api.currentUser(token: SessionToken("syntheticToken")).id == "user1")
  #expect(await delays.values == [0.5, 1])
  #expect(await transport.requests.count == 3)
}

@Test func retryBudgetEndsAfterThreeAttempts() async throws {
  let transport = ScriptedTransport(Array(repeating: .response(503, ""), count: 3))
  let delays = Delays()
  let api = try client(transport, sleep: { await delays.append($0) })
  await #expect(throws: APIError.http(status: 503, retryAfter: nil)) {
    try await api.currentUser(token: SessionToken("syntheticToken"))
  }
  #expect(await transport.requests.count == 3)
  #expect(await delays.values == [0.5, 1])
}

@Test(arguments: [429, 503])
func serverRetryMinimumIsRespected(status: Int) async throws {
  let transport = ScriptedTransport([
    .response(status, "", ["Retry-After": "3"]), .response(200, userJSON),
  ])
  let delays = Delays()
  _ = try await client(transport, sleep: { await delays.append($0) })
    .currentUser(token: SessionToken("syntheticToken"))
  #expect(await delays.values == [3])
}

@Test func longServerGuidanceReturnsWithoutEarlyRetry() async throws {
  let transport = ScriptedTransport([.response(429, "", ["Retry-After": "120"])])
  let api = try client(transport, sleep: { _ in Issue.record("Should not sleep") })
  await #expect(throws: APIError.rateLimited(retryAfter: 120)) {
    try await api.currentUser(token: SessionToken("syntheticToken"))
  }
  #expect(await transport.requests.count == 1)
}

@Test(arguments: [URLError.timedOut, .notConnectedToInternet, .secureConnectionFailed])
func networkFailuresAreTyped(code: URLError.Code) async throws {
  let transport = ScriptedTransport([.failure(code)])
  let api = try client(transport, policy: APIRetryPolicy(maximumAttempts: 1))
  let expected: APIError =
    code == .timedOut
    ? .timedOut
    : code == .notConnectedToInternet ? .offline : .network(code: code.rawValue)
  await #expect(throws: expected) {
    try await api.currentUser(token: SessionToken("syntheticToken"))
  }
}

@Test(arguments: [
  ScriptedTransport.Step.response(503, ""), .response(429, "", ["Retry-After": "1"]),
  .failure(.timedOut), .failure(.networkConnectionLost),
])
private func writesAndLoginNeverRetry(step: ScriptedTransport.Step) async throws {
  let transport = ScriptedTransport([step, step, step])
  let api = try client(transport, sleep: { _ in Issue.record("Writes must not retry") })
  let token = try SessionToken("syntheticToken")
  do {
    _ = try await api.createPost(CreatePost(channelID: "channel1", message: "Test"), token: token)
  } catch {}
  do { _ = try await api.login(LoginCredentials(loginID: "tester", password: "synthetic")) } catch {
  }
  do { try await api.logout(token: token) } catch {}
  #expect(await transport.requests.count == 3)
}

@Test func cancellationStopsInflightRequest() async throws {
  let transport = ScriptedTransport([.suspend])
  let api = try client(transport)
  let task = Task { try await api.currentUser(token: SessionToken("syntheticToken")) }
  // Bounded wait for the request to start; cancellation must reach the suspended transport.
  for _ in 0..<1000 {
    if await !transport.requests.isEmpty { break }
    try await Task.sleep(for: .milliseconds(1))
  }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(await transport.requests.count == 1)
}

@Test func cancellationDuringBackoffPreventsNextAttempt() async throws {
  let transport = ScriptedTransport([.response(503, "")])
  let enteredSleep = Mutex(false)
  let api = try client(
    transport,
    sleep: { _ in
      enteredSleep.withLock { $0 = true }
      try await Task.sleep(for: .seconds(60))
    })
  let task = Task { try await api.currentUser(token: SessionToken("syntheticToken")) }
  for _ in 0..<1000 {
    if enteredSleep.withLock({ $0 }) { break }
    try await Task.sleep(for: .milliseconds(1))
  }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(await transport.requests.count == 1)
}

@Test func loggingContainsOnlyFixedRequestMetadata() async throws {
  let events = Mutex<[APIRequestEvent]>([])
  let transport = ScriptedTransport([.response(200, userJSON, ["Token": "syntheticSecret"])])
  let api = try client(transport, log: { event in events.withLock { $0.append(event) } })
  _ = try await api.login(
    LoginCredentials(loginID: "private@example.com", password: "privatePassword"))
  #expect(
    events.withLock { $0 } == [
      APIRequestEvent(operation: .login, attempt: 1, outcome: .started),
      APIRequestEvent(operation: .login, attempt: 1, outcome: .response(status: 200)),
    ])
  let token = try SessionToken("syntheticSecret")
  let credentials = try LoginCredentials(
    loginID: "private@example.com", password: "privatePassword")
  #expect(String(reflecting: token) == "SessionToken(<redacted>)")
  #expect(String(reflecting: credentials) == "LoginCredentials(<redacted>)")
  #expect(Mirror(reflecting: token).children.isEmpty)
  #expect(Mirror(reflecting: credentials).children.isEmpty)
}
