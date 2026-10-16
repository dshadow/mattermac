import Darwin
import Foundation
import MattermacCore

/// Opt-in signed-app gate exercises the production credential implementation with fake data.
@MainActor enum SessionStoreContinuityProbe {
  static let revision = "phase3-rebuilt"

  static func runIfRequested() {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--session-store-continuity-probe") else { return }
    guard arguments.count == index + 3, let id = UUID(uuidString: arguments[index + 2]) else {
      finish("invalid arguments", success: false)
    }
    let action = arguments[index + 1]
    let store = KeychainSessionStore(probeID: id)
    do {
      let expected = SessionCredential(
        server: try MattermostServer("https://example.com/synthetic"), userID: "synthetic-user",
        token: try SessionToken("synthetic-session-\(id.uuidString)"))
      switch action {
      case "create":
        guard try store.load() == nil else { finish("item already exists", success: false) }
        try store.save(expected)
        guard try store.load() == expected else { finish("read mismatch", success: false) }
      case "verify":
        guard try store.load() == expected else { finish("read mismatch", success: false) }
      case "update":
        guard try store.load() == expected else { finish("read mismatch", success: false) }
        try store.save(expected)
        guard try store.load() == expected else { finish("update mismatch", success: false) }
      case "delete":
        try store.delete()
        guard try store.load() == nil else { finish("delete mismatch", success: false) }
      default: finish("invalid action", success: false)
      }
      finish("\(action) passed; revision=\(revision)", success: true)
    } catch {
      finish("\(action) failed", success: false)
    }
  }

  private static func finish(_ message: String, success: Bool) -> Never {
    print("Session store continuity probe: \(message)")
    exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
  }
}
