import Foundation

/// No mutable account state: each authenticated operation receives its own session token.
public struct MattermostAPIClient: Sendable {
  private let server: MattermostServer
  private let transport: any HTTPTransport
  private let requestTimeout: TimeInterval
  private let retryPolicy: APIRetryPolicy
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let now: @Sendable () -> Date
  private let log: @Sendable (APIRequestEvent) -> Void

  public init(
    server: MattermostServer,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    requestTimeout: TimeInterval = 30,
    retryPolicy: APIRetryPolicy = .standard,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    },
    now: @escaping @Sendable () -> Date = { Date() },
    log: @escaping @Sendable (APIRequestEvent) -> Void = APIRequestLogger.log
  ) throws {
    guard requestTimeout.isFinite, requestTimeout > 0, requestTimeout <= 60 else {
      throw APIError.invalidConfiguration
    }
    self.server = server
    self.transport = transport
    self.requestTimeout = requestTimeout
    self.retryPolicy = retryPolicy
    self.sleep = sleep
    self.now = now
    self.log = log
  }

  public func login(_ credentials: LoginCredentials) async throws -> LoginSession {
    let response = try await send(
      .login, path: ["users", "login"], body: encode(credentials))
    guard let value = response.response.value(forHTTPHeaderField: "Token"), !value.isEmpty else {
      throw APIError.missingSessionToken
    }
    return try LoginSession(user: decode(response), token: SessionToken(value))
  }

  /// Revokes only the supplied server session. Local credential cleanup belongs to Phase 3.
  public func logout(token: SessionToken) async throws {
    _ = try await send(.logout, path: ["users", "logout"], token: token)
  }

  public func currentUser(token: SessionToken) async throws -> MattermostUser {
    try decode(await send(.currentUser, path: ["users", "me"], token: token))
  }

  public func teams(token: SessionToken) async throws -> [MattermostTeam] {
    try decode(await send(.teams, path: ["users", "me", "teams"], token: token))
  }

  /// This membership endpoint returns all joined channels for the team, including DMs/groups.
  public func channels(teamID: String, token: SessionToken) async throws -> [MattermostChannel] {
    try decode(
      await send(
        .channels, path: ["users", "me", "teams", teamID, "channels"], token: token))
  }

  public func channelPosts(
    channelID: String, page: PostPage = .recent, token: SessionToken
  ) async throws -> ChannelPosts {
    try decode(
      await send(
        .channelPosts, path: ["channels", channelID, "posts"], query: page.query, token: token))
  }

  public func olderPosts(channelID: String, before postID: String, token: SessionToken)
    async throws -> ChannelPosts
  {
    guard !postID.isEmpty else { throw APIError.invalidPagination }
    let page: ChannelPosts = try decode(
      await send(
        .channelPosts, path: ["channels", channelID, "posts"],
        query: [
          URLQueryItem(name: "before", value: postID),
          URLQueryItem(name: "per_page", value: "100"),
        ], token: token))
    guard page.posts.count <= 200 else { throw APIError.decodingFailed }
    return page
  }

  public func avatar(userID: String, token: SessionToken) async throws -> Data {
    let response = try await send(.avatar, path: ["users", userID, "image"], token: token)
    guard response.data.count <= 262_144 else { throw APIError.decodingFailed }
    return response.data
  }

  /// Never automatically replay a send: a lost response can still mean the post was created.
  public func createPost(_ post: CreatePost, token: SessionToken) async throws -> MattermostPost {
    try decode(await send(.createPost, path: ["posts"], token: token, body: encode(post)))
  }

  public func postReactions(postID: String, token: SessionToken) async throws
    -> [MattermostReaction]
  {
    let reactions: [MattermostReaction]? = try decode(
      await send(.postReactions, path: ["posts", postID, "reactions"], token: token))
    return reactions ?? []
  }

  public func channelMemberships(teamID: String, token: SessionToken) async throws
    -> [NavigationMembership]
  {
    try decode(
      await send(
        .channelMemberships,
        path: ["users", "me", "teams", teamID, "channels", "members"], token: token))
  }

  public func users(ids: [String], token: SessionToken) async throws -> [MattermostUser] {
    guard !ids.isEmpty, ids.count <= 200 else { throw APIError.invalidConfiguration }
    return try decode(
      await send(
        .usersByIDs, path: ["users", "ids"], token: token,
        body: encode(ids)))
  }

  private func encode(_ body: some Encodable) throws -> Data {
    do { return try JSONEncoder().encode(body) } catch { throw APIError.encodingFailed }
  }

  private func decode<Value: Decodable>(_ response: HTTPResponse) throws -> Value {
    try Task.checkCancellation()
    do { return try JSONDecoder().decode(Value.self, from: response.data) } catch {
      throw APIError.decodingFailed
    }
  }

  private func send(
    _ operation: APIOperation, path: [String], query: [URLQueryItem] = [],
    token: SessionToken? = nil, body: Data? = nil
  ) async throws -> HTTPResponse {
    let isRead = ![APIOperation.login, .logout, .createPost].contains(operation)
    var request = URLRequest(
      url: try server.url(path: path, query: query),
      cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
    request.httpMethod = isRead && operation != .usersByIDs ? "GET" : "POST"
    request.httpShouldHandleCookies = false
    request.setValue(
      operation == .avatar ? "image/png" : "application/json", forHTTPHeaderField: "Accept")
    if let token { request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization") }
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let limit = isRead ? retryPolicy.maximumAttempts : 1
    for attempt in 1...limit {
      try Task.checkCancellation()
      log(APIRequestEvent(operation: operation, attempt: attempt, outcome: .started))
      let response: HTTPResponse
      do {
        response = try await transport.send(request)
        try Task.checkCancellation()
      } catch {
        if Task.isCancelled || error is CancellationError
          || (error as? URLError)?.code == .cancelled
        {
          log(APIRequestEvent(operation: operation, attempt: attempt, outcome: .cancelled))
          throw CancellationError()
        }
        let failure = Self.networkError(error)
        log(APIRequestEvent(operation: operation, attempt: attempt, outcome: .failed))
        if attempt < limit, Self.isRetryable(failure),
          let delay = retryPolicy.delay(attempt: attempt, serverMinimum: nil)
        {
          try await sleep(delay)
          continue
        }
        throw failure
      }

      let status = response.response.statusCode
      log(
        APIRequestEvent(operation: operation, attempt: attempt, outcome: .response(status: status)))
      if (200...299).contains(status) { return response }
      let minimum = APIRetryPolicy.serverDelay(response.response, now: now())
      if attempt < limit, [408, 429, 500, 502, 503, 504].contains(status),
        let delay = retryPolicy.delay(attempt: attempt, serverMinimum: minimum)
      {
        try await sleep(delay)
        continue
      }
      switch status {
      case 401: throw APIError.unauthorized
      case 403: throw APIError.forbidden
      case 429: throw APIError.rateLimited(retryAfter: minimum)
      default: throw APIError.http(status: status, retryAfter: minimum)
      }
    }
    throw APIError.transportFailed
  }

  private static func networkError(_ error: any Error) -> APIError {
    if let error = error as? APIError { return error }
    guard let error = error as? URLError else { return .transportFailed }
    switch error.code {
    case .timedOut: return .timedOut
    case .notConnectedToInternet: return .offline
    default: return .network(code: error.errorCode)
    }
  }

  private static func isRetryable(_ error: APIError) -> Bool {
    switch error {
    case .timedOut: return true
    case .network(let code):
      return [URLError.networkConnectionLost.rawValue, URLError.cannotConnectToHost.rawValue]
        .contains(code)
    default: return false
    }
  }
}
