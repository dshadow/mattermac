import Foundation
import LocalAuthentication
import Security

public enum CredentialStoreError: Error { case unavailable, invalidRecord }

/// File-based Keychain supports the project's stable, local self-signed identity.
/// No synchronizable items, access groups, passwords or MFA secrets are stored.
@MainActor public struct KeychainSessionStore: SessionCredentialStore {
  private let service: String
  private let account: String

  public init() {
    service = AppIdentity.bundleIdentifier + ".session"
    account = "active-session"
  }

  /// Development sessions never replace the normal app's active credential.
  public init(localTesting: Bool) {
    service = AppIdentity.bundleIdentifier + (localTesting ? ".local-test-session" : ".session")
    account = "active-session"
  }

  /// A distinct service keeps synthetic app-process continuity checks isolated.
  public init(probeID: UUID) {
    service = AppIdentity.bundleIdentifier + ".session-probe"
    account = probeID.uuidString
  }

  private var query: [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: false,
      kSecUseAuthenticationContext as String: context,
    ]
  }

  public func load() throws -> SessionCredential? {
    var attributes = query
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw CredentialStoreError.unavailable }
    guard let data = result as? Data,
      let record = try? JSONDecoder().decode(SessionCredential.self, from: data),
      !record.userID.isEmpty, (try? record.token) != nil
    else { throw CredentialStoreError.invalidRecord }
    return record
  }

  public func save(_ credential: SessionCredential) throws {
    let data = try JSONEncoder().encode(credential)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecItemNotFound {
      var attributes = query
      attributes[kSecValueData as String] = data
      guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
        throw CredentialStoreError.unavailable
      }
    } else if status != errSecSuccess {
      throw CredentialStoreError.unavailable
    }
  }

  public func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialStoreError.unavailable
    }
  }
}
