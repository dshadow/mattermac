import Darwin
import Foundation
import LocalAuthentication
import Security

/// Opt-in, app-process check for local signed rebuilds. Never touches account credentials.
enum KeychainContinuityProbe {
  // Change this marker between probe builds to ensure the executable actually changes.
  static let revision = "rebuilt"

  static func runIfRequested() {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--keychain-continuity-probe") else { return }
    guard arguments.count == index + 3,
      let runID = UUID(uuidString: arguments[index + 2])
    else {
      finish("invalid arguments", success: false)
    }

    let action = arguments[index + 1]
    let context = LAContext()
    context.interactionNotAllowed = true
    // Use the file-based Keychain: local self-signed identities have no Apple access group.
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "io.github.dshadow.mattermac.keychain-continuity-probe",
      kSecAttrAccount as String: runID.uuidString,
      kSecUseDataProtectionKeychain as String: false,
      kSecUseAuthenticationContext as String: context,
    ]
    let expected = Data("synthetic-keychain-probe:\(runID.uuidString)".utf8)

    switch action {
    case "create":
      var attributes = query
      attributes[kSecValueData as String] = expected
      let status = SecItemAdd(attributes as CFDictionary, nil)
      guard status == errSecSuccess else { fail(action, status: status) }
      verify(query, expected: expected)
    case "verify":
      verify(query, expected: expected)
    case "delete":
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess else { fail(action, status: status) }
      let remaining = SecItemCopyMatching(query as CFDictionary, nil)
      guard remaining == errSecItemNotFound else { fail("confirm deletion", status: remaining) }
    default:
      finish("unknown action", success: false)
    }
    finish("\(action) passed; revision=\(revision)", success: true)
  }

  private static func verify(_ query: [String: Any], expected: Data) {
    var readQuery = query
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
    guard status == errSecSuccess else { fail("verify", status: status) }
    guard let data = result as? Data, data == expected else {
      finish("value mismatch", success: false)
    }
  }

  private static func fail(_ action: String, status: OSStatus) -> Never {
    finish("\(action) failed; OSStatus=\(status)", success: false)
  }

  private static func finish(_ message: String, success: Bool) -> Never {
    print("Keychain continuity probe: \(message)")
    exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
  }
}
