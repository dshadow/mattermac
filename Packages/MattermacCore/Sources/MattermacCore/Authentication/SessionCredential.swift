import Foundation

/// The entire record belongs in Keychain, never preferences or the message store.
public struct SessionCredential: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let serverAddress: String
  public let userID: String
  private let secret: String

  public init(server: MattermostServer, userID: String, token: SessionToken) {
    serverAddress = server.baseURL.absoluteString
    self.userID = userID
    secret = token.value
  }

  public var token: SessionToken { get throws { try SessionToken(secret) } }
  public var description: String { "SessionCredential(<redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

@MainActor public protocol SessionCredentialStore {
  func load() throws -> SessionCredential?
  func save(_ credential: SessionCredential) throws
  func delete() throws
}

public struct SessionAccount: Equatable, Sendable {
  public let serverAddress: String
  public let userID: String

  public init(serverAddress: String, userID: String) {
    self.serverAddress = serverAddress
    self.userID = userID
  }
}

/// Future persistence/send queues must implement this boundary before exposing account data.
/// Pause preserves durable work. Reconcile resolves uncertain sends before allowing new sends.
@MainActor public protocol AccountSessionData {
  func hasUnsentContent(for account: SessionAccount) -> Bool
  func pause(for account: SessionAccount)
  func reconcile(for account: SessionAccount) async throws
  /// Delete app-owned cache, drafts, pending sends and account-scoped secrets; keep exports.
  func clear(for account: SessionAccount) async throws
}

/// Phase 3 has no message cache, drafts, pending sends or extra account Keychain items.
@MainActor public struct EmptyAccountSessionData: AccountSessionData {
  public init() {}
  public func hasUnsentContent(for account: SessionAccount) -> Bool { false }
  public func pause(for account: SessionAccount) {}
  public func reconcile(for account: SessionAccount) async throws {}
  public func clear(for account: SessionAccount) async throws {}
}
