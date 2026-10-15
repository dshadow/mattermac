import OSLog

public enum APIOperation: String, Sendable {
  case login, logout, currentUser, teams, channels, channelPosts, createPost
}

/// Fixed operation names and numeric metadata only. No account or server identifiers.
public struct APIRequestEvent: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    case started
    case response(status: Int)
    case failed
    case cancelled
  }

  public let operation: APIOperation
  public let attempt: Int
  public let outcome: Outcome
}

public enum APIRequestLogger {
  private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "HTTP")

  public static func log(_ event: APIRequestEvent) {
    let operation = event.operation.rawValue
    switch event.outcome {
    case .started:
      logger.debug("HTTP \(operation, privacy: .public) attempt \(event.attempt) started")
    case .response(let status):
      logger.debug("HTTP \(operation, privacy: .public) attempt \(event.attempt) status \(status)")
    case .failed:
      logger.debug("HTTP \(operation, privacy: .public) attempt \(event.attempt) failed")
    case .cancelled:
      logger.debug("HTTP \(operation, privacy: .public) attempt \(event.attempt) cancelled")
    }
  }
}
