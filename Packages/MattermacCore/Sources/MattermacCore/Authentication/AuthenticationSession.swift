import Foundation
import Observation

public enum AuthenticationPhase: Equatable, Sendable {
  case starting, signedOut, verificationRequired, reauthenticationRequired, authenticated,
    cleanupRequired
}

public enum AuthenticationError: Error { case sessionUnavailable, staleSession }

/// Shared by all windows. Secrets stay private; callbacks are scoped to a session generation.
@MainActor @Observable public final class AuthenticationSession {
  public private(set) var phase: AuthenticationPhase = .starting
  public private(set) var isBusy = false
  public private(set) var user: MattermostUser?
  public private(set) var serverAddress = ""
  public private(set) var message: String?
  public let realtime: RealtimeSession?

  private let store: any SessionCredentialStore
  private let accountData: any AccountSessionData
  public let allowInsecureLocalhost: Bool
  private let makeClient: (MattermostServer) throws -> MattermostAPIClient
  private var credential: SessionCredential?
  private var generation = UUID()
  private var started = false
  private var checkingSession = false

  public init(
    store: any SessionCredentialStore = KeychainSessionStore(),
    accountData: any AccountSessionData = EmptyAccountSessionData(),
    realtime: RealtimeSession? = nil,
    allowInsecureLocalhost: Bool = false,
    makeClient: @escaping (MattermostServer) throws -> MattermostAPIClient = {
      try MattermostAPIClient(server: $0)
    }
  ) {
    self.store = store
    self.accountData = accountData
    self.realtime = realtime
    self.allowInsecureLocalhost = allowInsecureLocalhost
    self.makeClient = makeClient
  }

  public var account: SessionAccount? {
    credential.map { SessionAccount(serverAddress: $0.serverAddress, userID: $0.userID) }
  }

  public var logoutNeedsConfirmation: Bool {
    account.map { accountData.hasUnsentContent(for: $0) } ?? false
  }

  public func start() async {
    guard !started else { return }
    started = true
    await restore()
  }

  public func restore() async {
    guard !isBusy, phase == .starting || phase == .verificationRequired else { return }
    isBusy = true
    defer { isBusy = false }
    message = nil
    do {
      if credential == nil { credential = try store.load() }
      guard let credential else {
        phase = .signedOut
        return
      }
      serverAddress = credential.serverAddress
      phase = .verificationRequired
      let client = try makeClient(server(serverAddress))
      let verified = try await client.currentUser(token: credential.token)
      guard verified.id == credential.userID else { throw AuthenticationError.staleSession }
      try await activate(verified)
    } catch {
      if credential == nil { phase = .verificationRequired }
      if error as? APIError == .unauthorized {
        expire()
      } else {
        message = "Could not verify your saved session. Retry, or sign out to remove it."
      }
    }
  }

  public func login(address: String, loginID: String, password: String, mfaCode: String) async {
    guard !isBusy, phase == .signedOut || phase == .reauthenticationRequired else { return }
    isBusy = true
    defer { isBusy = false }
    message = nil
    var issued: LoginSession?
    var client: MattermostAPIClient?
    do {
      let server = try server(address.trimmingCharacters(in: .whitespacesAndNewlines))
      if let credential, credential.serverAddress != server.baseURL.absoluteString {
        throw AuthenticationError.staleSession
      }
      let api = try makeClient(server)
      client = api
      let result = try await api.login(
        LoginCredentials(
          loginID: loginID.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
          mfaCode: mfaCode.isEmpty ? nil : mfaCode))
      issued = result
      guard !result.user.id.isEmpty else { throw APIError.invalidResponse }
      if let credential, credential.userID != result.user.id {
        throw AuthenticationError.staleSession
      }
      let saved = SessionCredential(server: server, userID: result.user.id, token: result.token)
      try store.save(saved)
      credential = saved
      serverAddress = saved.serverAddress
      phase = .reauthenticationRequired
      try await activate(result.user)
    } catch {
      // A failed local save, identity check or reconciliation must not leak an issued session.
      if let issued, let client { try? await client.logout(token: issued.token) }
      message = Self.loginMessage(error)
    }
  }

  /// Caller must ask before discarding unsent content. Cancellation leaves everything intact.
  public func logout(discardUnsent: Bool = false) async {
    guard !isBusy, !logoutNeedsConfirmation || discardUnsent else { return }
    isBusy = true
    defer { isBusy = false }
    generation = UUID()
    realtime?.stop()
    user = nil
    phase = .cleanupRequired
    if let account { accountData.pause(for: account) }
    var revoked = true
    if let credential {
      do {
        let api = try makeClient(server(credential.serverAddress))
        try await api.logout(token: credential.token)
      } catch {
        revoked = (error as? APIError) == .unauthorized
      }
    }
    do {
      if let account { try await accountData.clear(for: account) }
      try store.delete()
      credential = nil
      serverAddress = ""
      phase = .signedOut
      message = revoked ? nil : "Signed out locally. Server revocation could not be confirmed."
    } catch {
      message = "Local cleanup failed. Sign out again to finish removing account data."
    }
  }

  public func verify() async {
    guard phase == .authenticated, !isBusy, !checkingSession else { return }
    checkingSession = true
    defer { checkingSession = false }
    let current = generation
    do {
      let verified = try await perform { try await $0.currentUser(token: $1) }
      message = nil
      if verified.id != credential?.userID { expire() }
    } catch {
      if current == generation, phase == .authenticated {
        message = "Session check unavailable. Try again when connected."
      }
    }
  }

  /// Route authenticated REST work through here. UI consumers must also scope state by account.
  public func perform<Value: Sendable>(
    _ operation: @Sendable (MattermostAPIClient, SessionToken) async throws -> Value
  ) async throws -> Value {
    guard phase == .authenticated, !isBusy, let credential else {
      throw AuthenticationError.sessionUnavailable
    }
    let current = generation
    do {
      let client = try makeClient(server(credential.serverAddress))
      let result = try await operation(client, credential.token)
      guard current == generation, phase == .authenticated else {
        throw AuthenticationError.staleSession
      }
      return result
    } catch {
      guard current == generation else { throw AuthenticationError.staleSession }
      if error as? APIError == .unauthorized { expire() }
      throw error
    }
  }

  private func activate(_ verified: MattermostUser) async throws {
    guard let account else { throw AuthenticationError.sessionUnavailable }
    try await accountData.reconcile(for: account)
    try Task.checkCancellation()
    generation = UUID()
    user = verified
    phase = .authenticated
    if let credential {
      let current = generation
      realtime?.start(credential: credential) { [weak self] in
        guard let self, self.generation == current, self.phase == .authenticated else { return }
        self.expire()
      }
    }
  }

  private func server(_ address: String) throws -> MattermostServer {
    try MattermostServer(address, allowInsecureLocalhost: allowInsecureLocalhost)
  }

  private func expire() {
    generation = UUID()
    realtime?.stop()
    if let account { accountData.pause(for: account) }
    user = nil
    phase = .reauthenticationRequired
    message = "Your session expired. Sign in to the same account to continue."
  }

  private static func loginMessage(_ error: any Error) -> String {
    switch error {
    case APIError.invalidServerURL: "Enter a valid HTTPS server address."
    case APIError.unauthorized, APIError.forbidden, APIError.invalidCredentials,
      APIError.http(status: 400, retryAfter: _):
      "Sign-in failed. Check your username, password and authentication code if MFA is enabled."
    case APIError.rateLimited: "Too many attempts. Wait before trying again."
    case APIError.offline, APIError.timedOut, APIError.network:
      "Could not reach the server. Check your connection and try again."
    case is CredentialStoreError:
      "Could not save the session in Keychain. Unlock your Keychain and try again."
    case is AuthenticationError:
      "Sign in to the original account, or sign out before switching accounts."
    default: "Sign-in could not finish. Check the server address and try again."
    }
  }
}
