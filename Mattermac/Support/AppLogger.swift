import MattermacCore
import OSLog

enum AppLogger {
  // Keep lifecycle logs free of account identifiers, credentials, and message contents.
  static let lifecycle = Logger(subsystem: AppIdentity.bundleIdentifier, category: "Lifecycle")
}
