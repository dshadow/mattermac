import Foundation

public enum OutgoingState: String, Codable, Sendable {
  case draft, queued, submitting, uncertain, sent, failed
}

/// Local identifier is stable across restart. Future sending must reconcile uncertain outcomes
/// with Mattermost before replay; this repository never sends or automatically retries a message.
public struct OutgoingMessage: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let channelID: String
  public let rootID: String
  public let message: String
  public let state: OutgoingState
  public let createdAt: Date
  public init(
    id: UUID = UUID(), channelID: String, rootID: String = "", message: String,
    state: OutgoingState = .draft, createdAt: Date = Date()
  ) {
    self.id = id
    self.channelID = channelID
    self.rootID = rootID
    self.message = message
    self.state = state
    self.createdAt = createdAt
  }
}

public struct OutgoingRepository: Sendable {
  public let persistence: PersistenceController
  init(_ persistence: PersistenceController) { self.persistence = persistence }

  public func save(_ message: OutgoingMessage) async throws {
    try await persistence.transaction { context, _ in
      try Records.put(
        context, kind: "outgoing", id: message.id.uuidString, value: message,
        channel: message.channelID, root: message.rootID,
        sortAt: Int64(message.createdAt.timeIntervalSince1970 * 1_000), now: Date())
    }
  }

  public func messages(before: PostCursor? = nil, limit: Int = 200) async throws
    -> [OutgoingMessage]
  {
    try await persistence.transaction { context, _ in
      let predicate: NSPredicate
      if let before {
        predicate = NSPredicate(
          format: "kind == 'outgoing' AND (sortAt < %lld OR (sortAt == %lld AND id < %@))",
          before.createdAt, before.createdAt, before.id)
      } else {
        predicate = NSPredicate(format: "kind == 'outgoing'")
      }
      return try Records.fetch(
        context, predicate: predicate, limit: min(limit, 200),
        sort: [
          NSSortDescriptor(key: "sortAt", ascending: false),
          NSSortDescriptor(key: "id", ascending: false),
        ]
      )
      .map { try Records.decode($0) }
    }
  }

  public func hasUnsentContent() async throws -> Bool {
    // Sent records are deleted upon acknowledgement; all remaining records protect logout.
    try await persistence.transaction { context, _ in
      try !Records.fetch(context, predicate: NSPredicate(format: "kind == 'outgoing'"), limit: 1)
        .isEmpty
    }
  }

  public func remove(id: UUID) async throws {
    try await persistence.transaction { context, _ in
      if let object = try Records.find(context, "outgoing", id.uuidString) {
        context.delete(object)
      }
    }
  }
}
