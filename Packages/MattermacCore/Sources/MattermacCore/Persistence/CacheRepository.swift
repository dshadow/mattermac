import CoreData
import Foundation

public struct PostCursor: Sendable, Equatable {
  public let createdAt: Int64
  public let id: String
  public init(createdAt: Int64, id: String) {
    self.createdAt = createdAt
    self.id = id
  }
}

public struct CachedPostPage: Sendable {
  public let posts: [MattermostPost]
  public let next: PostCursor?
}

public struct ChannelReadState: Codable, Sendable, Equatable {
  public let channelID: String
  public let lastViewedAt: Int64
  public let mentionCount: Int
  public init(channelID: String, lastViewedAt: Int64, mentionCount: Int) {
    self.channelID = channelID
    self.lastViewedAt = lastViewedAt
    self.mentionCount = mentionCount
  }
}

public struct CacheSnapshot: Sendable {
  public let channels: [MattermostChannel]
  public let selectedChannelID: String?
  public let posts: [MattermostPost]
  public let reactions: [MattermostReaction]
}

/// Typed value boundary for disposable server data. No tokens or credentials accepted here.
public struct CacheRepository: Sendable {
  public let persistence: PersistenceController
  init(_ persistence: PersistenceController) { self.persistence = persistence }

  public func saveIdentity(_ user: MattermostUser, teams: [MattermostTeam]) async throws {
    try await persistence.transaction { context, _ in
      try Records.put(context, kind: "user", id: user.id, value: user, now: Date())
      for team in teams {
        try Records.put(context, kind: "team", id: team.id, value: team, now: Date())
      }
    }
  }

  public func user(id: String) async throws -> MattermostUser? {
    try await persistence.transaction { context, _ in
      guard let object = try Records.find(context, "user", id) else { return nil }
      object.setValue(Date(), forKey: "accessedAt")
      return try Records.decode(object)
    }
  }

  /// Complete joined-channel membership snapshot. Permission purges use bounded, idempotent batches
  /// before membership publication; a failed purge blocks publication and is retried on recovery.
  public func replaceChannels(_ channels: [MattermostChannel]) async throws {
    guard channels.count <= 10_000 else { throw PersistenceError.invalidData }
    try await persistence.transaction { context, _ in
      let allowed = Set(channels.map(\.id))
      let old = try Records.fetch(
        context, predicate: NSPredicate(format: "kind == 'channel'"), limit: 10_000)
      for object in old {
        if let id = object.value(forKey: "id") as? String, !allowed.contains(id) {
          try Records.delete(context, predicate: NSPredicate(format: "channelID == %@", id))
        }
      }
      for channel in channels {
        let previousAccess =
          try Records.find(context, "channel", channel.id)?.value(forKey: "accessedAt") as? Date
        try Records.put(
          context, kind: "channel", id: channel.id, value: channel, channel: channel.id, now: Date()
        )
        if let previousAccess {
          try Records.find(context, "channel", channel.id)?.setValue(
            previousAccess, forKey: "accessedAt")
        }
      }
    }
  }

  public func selectChannel(_ id: String) async throws {
    try await persistence.transaction { context, _ in
      guard let channel = try Records.find(context, "channel", id) else {
        throw PersistenceError.invalidData
      }
      channel.setValue(Date(), forKey: "accessedAt")
      try Records.put(context, kind: "selection", id: "current", value: id, now: Date())
    }
  }

  public func beginImport() async throws -> Int64 {
    try await persistence.transaction { _, sequence in sequence }
  }

  public func post(id: String) async throws -> MattermostPost? {
    try await persistence.transaction { context, _ in
      guard let object = try Records.find(context, "post", id),
        object.value(forKey: "isTombstone") as? Bool != true
      else { return nil }
      return try Records.decode(object)
    }
  }

  /// Revision checks and tombstones survive restarts. Checkpoint commits in the same save as posts.
  /// A latest-page import retires the previous visible window only; older history remains paginated.
  public func importPosts(
    _ incoming: [MattermostPost], channelID: String, checkpoint: UUID = UUID(),
    deletedIDs: Set<String> = [], authoritativeWindow: Set<String>? = nil,
    ticket: Int64 = .max, reactions: [MattermostReaction]? = nil, now: Date = Date()
  ) async throws {
    guard incoming.count <= 200, reactions?.count ?? 0 <= 2_000 else {
      throw PersistenceError.invalidData
    }
    try await persistence.transaction { context, sequence in
      guard let channel = try Records.find(context, "channel", channelID) else { return }
      channel.setValue(now, forKey: "accessedAt")
      if let authoritativeWindow {
        let ids = Set(incoming.map(\.id))
        let oldest = incoming.min { ($0.createAt, $0.id) < ($1.createAt, $1.id) }
        for id in authoritativeWindow.subtracting(ids) {
          if let object = try Records.find(context, "post", id),
            (object.value(forKey: "sequence") as? Int64 ?? 0) <= ticket
          {
            // A full page can displace older posts without deleting them.
            if incoming.count == 200, let oldest,
              let created = object.value(forKey: "sortAt") as? Int64,
              (created, id) < (oldest.createAt, oldest.id)
            {
              continue
            }
            object.setValue(true, forKey: "isTombstone")
            object.setValue(nil, forKey: "payload")
          }
        }
      }
      for post in incoming where post.channelID == channelID {
        let previous = try Records.find(context, "post", post.id)
        let deleted = deletedIDs.contains(post.id) || post.deleteAt > 0
        if !deleted {
          if previous?.value(forKey: "isTombstone") as? Bool == true { continue }
          if let revision = previous?.value(forKey: "revision") as? Int64, revision >= post.updateAt
          {
            continue
          }
        }
        try Records.put(
          context, kind: "post", id: post.id, value: post, channel: channelID, root: post.rootID,
          sortAt: post.createAt, revision: max(post.updateAt, post.deleteAt), deleted: deleted,
          sequence: sequence, now: now)
        if deleted { try Records.find(context, "post", post.id)?.setValue(nil, forKey: "payload") }
      }
      var windowIDs = Set(incoming.map(\.id))
      if authoritativeWindow == nil {
        if let previous = try Records.find(context, "window", channelID) {
          windowIDs.formUnion(try Records.decode(previous, as: [String].self))
        }
      } else {
        let concurrent = try Records.fetch(
          context,
          predicate: NSPredicate(
            format: "kind == 'post' AND channelID == %@ AND sequence > %lld", channelID, ticket),
          limit: 200,
          sort: [
            NSSortDescriptor(key: "sortAt", ascending: false),
            NSSortDescriptor(key: "id", ascending: false),
          ])
        windowIDs.formUnion(concurrent.compactMap { $0.value(forKey: "id") as? String })
      }
      let window = try Records.fetch(
        context,
        predicate: NSPredicate(
          format: "kind == 'post' AND channelID == %@ AND isTombstone == NO AND id IN %@",
          channelID, Array(windowIDs)),
        limit: 200,
        sort: [
          NSSortDescriptor(key: "sortAt", ascending: false),
          NSSortDescriptor(key: "id", ascending: false),
        ])
      try Records.put(
        context, kind: "window", id: channelID,
        value: window.compactMap { $0.value(forKey: "id") as? String }, channel: channelID, now: now
      )
      if let reactions {
        // REST baseline must not overwrite reaction events received during the request.
        let prior = try Records.find(context, "reactions", channelID)
        if (prior?.value(forKey: "sequence") as? Int64 ?? 0) <= ticket {
          try Records.put(
            context, kind: "reactions", id: channelID, value: reactions,
            channel: channelID, sequence: sequence, now: now)
        }
      }
      try Records.put(
        context, kind: "checkpoint", id: channelID, value: checkpoint,
        channel: channelID, now: now)
    }
  }

  /// Latest authoritative UI window stays distinct from older cached history.
  public func recentPosts(channelID: String) async throws -> [MattermostPost] {
    try await persistence.transaction { context, _ in
      try Records.find(context, "channel", channelID)?.setValue(Date(), forKey: "accessedAt")
      guard let window = try Records.find(context, "window", channelID) else { return [] }
      let ids = try Records.decode(window, as: [String].self)
      return try Records.fetch(
        context,
        predicate: NSPredicate(
          format: "kind == 'post' AND channelID == %@ AND isTombstone == NO AND id IN %@",
          channelID, ids),
        limit: 200,
        sort: [
          NSSortDescriptor(key: "sortAt", ascending: false),
          NSSortDescriptor(key: "id", ascending: false),
        ]
      )
      .map { try Records.decode($0) }
    }
  }

  public func invalidateMemberships() async throws {
    try await replaceChannels([])
    try await persistence.transaction { context, _ in
      try Records.delete(context, predicate: NSPredicate(format: "kind == 'team'"))
    }
  }

  public func applyReaction(_ reaction: MattermostReaction, added: Bool, channelID: String)
    async throws
  {
    try await persistence.transaction { context, sequence in
      var values = Set<MattermostReaction>()
      if let previous = try Records.find(context, "reactions", channelID) {
        values = Set(try Records.decode(previous, as: [MattermostReaction].self))
      }
      if added { values.insert(reaction) } else { values.remove(reaction) }
      guard values.count <= 2_000 else { throw PersistenceError.invalidData }
      try Records.put(
        context, kind: "reactions", id: channelID, value: Array(values),
        channel: channelID, sequence: sequence, now: Date())
    }
  }

  public func posts(
    channelID: String, rootID: String? = nil, before: PostCursor? = nil, limit: Int = 200
  ) async throws -> CachedPostPage {
    try await persistence.transaction { context, _ in
      var predicates = [
        NSPredicate(format: "kind == 'post' AND channelID == %@ AND isTombstone == NO", channelID)
      ]
      if let rootID {
        predicates.append(NSPredicate(format: "rootID == %@ OR id == %@", rootID, rootID))
      }
      if let before {
        predicates.append(
          NSPredicate(
            format: "sortAt < %lld OR (sortAt == %lld AND id < %@)", before.createdAt,
            before.createdAt, before.id))
      }
      let objects = try Records.fetch(
        context, predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates),
        limit: min(max(limit, 1), 200),
        sort: [
          NSSortDescriptor(key: "sortAt", ascending: false),
          NSSortDescriptor(key: "id", ascending: false),
        ])
      if let channel = try Records.find(context, "channel", channelID) {
        channel.setValue(Date(), forKey: "accessedAt")
      }
      let posts = try objects.map { try Records.decode($0, as: MattermostPost.self) }
      return CachedPostPage(
        posts: posts, next: posts.last.map { PostCursor(createdAt: $0.createAt, id: $0.id) })
    }
  }

  public func saveReadState(_ state: ChannelReadState) async throws {
    try await persistence.transaction { context, _ in
      try Records.put(
        context, kind: "read", id: state.channelID, value: state, channel: state.channelID,
        now: Date())
    }
  }

  public func readState(channelID: String) async throws -> ChannelReadState? {
    try await persistence.transaction { context, _ in
      try Records.find(context, "read", channelID).map { try Records.decode($0) }
    }
  }

  public func checkpoint(channelID: String) async throws -> UUID? {
    try await persistence.transaction { context, _ in
      try Records.find(context, "checkpoint", channelID).map { try Records.decode($0) }
    }
  }

  public func snapshot() async throws -> CacheSnapshot {
    let metadata: ([MattermostChannel], String?) = try await persistence.transaction { context, _ in
      let channels = try Records.fetch(
        context, predicate: NSPredicate(format: "kind == 'channel'"), limit: 10_000
      )
      .map { try Records.decode($0, as: MattermostChannel.self) }
      let selected: String? = try Records.find(context, "selection", "current").map {
        try Records.decode($0)
      }
      return (channels, selected)
    }
    let selected =
      metadata.0.first(where: { $0.id == metadata.1 })?.id
      ?? metadata.0.sorted { $0.id < $1.id }.first?.id
    let posts = try await selected.mapAsync { try await self.recentPosts(channelID: $0) } ?? []
    let reactions: [MattermostReaction] = try await persistence.transaction { context, _ in
      guard let selected, let object = try Records.find(context, "reactions", selected) else {
        return []
      }
      return try Records.decode(object)
    }
    return CacheSnapshot(
      channels: metadata.0, selectedChannelID: selected, posts: posts, reactions: reactions)
  }

  /// Evict complete inactive channels, including tombstones/checkpoints, as one cache epoch.
  public func evict(retentionDays: Int, activeChannelID: String? = nil, now: Date = Date())
    async throws
  {
    let cutoff = now.addingTimeInterval(-Double(max(1, min(retentionDays, 365))) * 86_400)
    try await persistence.transaction { context, _ in
      let expired = try Records.fetch(
        context,
        predicate: NSPredicate(format: "kind == 'channel' AND accessedAt < %@", cutoff as NSDate),
        limit: 10_000)
      for channel in expired {
        if let id = channel.value(forKey: "id") as? String, id != activeChannelID {
          try Records.delete(context, predicate: NSPredicate(format: "channelID == %@", id))
        }
      }
      try Records.delete(
        context,
        predicate: NSPredicate(
          format: "kind IN %@ AND accessedAt < %@", ["user", "team"], cutoff as NSDate))
    }
  }
}

extension Optional where Wrapped: Sendable {
  fileprivate func mapAsync<T: Sendable>(_ transform: (Wrapped) async throws -> T) async rethrows
    -> T?
  {
    guard let value = self else { return nil }
    return try await transform(value)
  }
}
