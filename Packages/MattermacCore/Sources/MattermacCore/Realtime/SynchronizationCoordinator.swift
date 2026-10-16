import Foundation
import Observation

public enum SynchronizationOrigin: Sendable { case live, recovery }

public struct MattermostReaction: Codable, Sendable, Hashable {
  public let userID: String
  public let postID: String
  public let emojiName: String
  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case postID = "post_id"
    case emojiName = "emoji_name"
  }
}

/// Publishes bounded value snapshots after the session commits repository transactions.
@MainActor @Observable public final class SynchronizationCoordinator {
  public private(set) var channels: [MattermostChannel] = []
  public private(set) var selectedChannelID: String?
  public private(set) var posts: [MattermostPost] = []
  public private(set) var statuses: [String: String] = [:]
  public private(set) var typing: [String: Date] = [:]
  public private(set) var reactionChanges: [MattermostReaction: Bool] = [:]
  public private(set) var reactions: Set<MattermostReaction> = []
  public private(set) var notificationRevision: UInt64 = 0
  public private(set) var mentionPostIDs: [String] = []
  public private(set) var checkpoint: UUID?

  private var generation = UUID()
  private var windowGeneration = UUID()
  private var values: [String: MattermostPost] = [:]
  private var tombstones: Set<String> = []
  private var mutationCounter: UInt64 = 0
  private var mutations: [String: UInt64] = [:]
  private var notified: Set<String> = []
  private var reactionMutations: [MattermostReaction: UInt64] = [:]

  public init() {}

  func restore(_ snapshot: CacheSnapshot) {
    setChannels(snapshot.channels)
    selectChannel(snapshot.selectedChannelID)
    if let ticket = beginImport() {
      let page = ChannelPosts(
        order: snapshot.posts.map(\.id),
        posts: Dictionary(uniqueKeysWithValues: snapshot.posts.map { ($0.id, $0) }))
      commit(page, reactions: snapshot.reactions, ticket: ticket)
    }
  }

  struct ImportTicket: Sendable {
    let generation: UUID
    let window: UUID
    let channelID: String
    let mutation: UInt64
  }

  func reset() {
    generation = UUID()
    channels = []
    selectedChannelID = nil
    statuses = [:]
    notified = []
    mentionPostIDs = []
    notificationRevision = 0
    resetWindow()
  }

  func resetWindow() {
    windowGeneration = UUID()
    values = [:]
    posts = []
    tombstones = []
    mutations = [:]
    typing = [:]
    reactionChanges = [:]
    reactions = []
    reactionMutations = [:]
    checkpoint = nil
  }

  func setChannels(_ incoming: [MattermostChannel]) {
    channels = incoming.sorted { ($0.displayName, $0.id) < ($1.displayName, $1.id) }
    if !channels.contains(where: { $0.id == selectedChannelID }) {
      selectChannel(channels.first(where: { $0.type == "O" })?.id ?? channels.first?.id)
    }
  }

  func selectChannel(_ id: String?) {
    guard id != selectedChannelID else { return }
    selectedChannelID = id
    resetWindow()
  }

  func beginImport() -> ImportTicket? {
    guard let channelID = selectedChannelID else { return nil }
    return ImportTicket(
      generation: generation, window: windowGeneration, channelID: channelID,
      mutation: mutationCounter)
  }

  /// A complete latest-200 response replaces the window, recovering missed deletes too.
  /// Overlay events received during the request; never resurrect a session tombstone.
  @discardableResult func commit(
    _ page: ChannelPosts, reactions baseline: [MattermostReaction] = [], ticket: ImportTicket,
    checkpoint: UUID = UUID()
  ) -> Bool {
    guard ticket.generation == generation, ticket.window == windowGeneration,
      ticket.channelID == selectedChannelID
    else { return false }
    let deleted = Set(
      page.posts.values.filter {
        $0.channelID == ticket.channelID && $0.deleteAt > 0
      }.map(\.id))
    guard tombstones.union(deleted).count <= 2_000 else {
      resetWindow()
      return false
    }
    tombstones.formUnion(deleted)
    for id in deleted { rememberNotification(id) }
    var imported: [String: MattermostPost] = [:]
    for post in page.posts.values where post.channelID == ticket.channelID {
      guard !tombstones.contains(post.id), post.deleteAt == 0 else { continue }
      if let current = values[post.id], current.updateAt >= post.updateAt {
        imported[post.id] = current
      } else {
        imported[post.id] = post
      }
    }
    for (id, counter) in mutations where counter > ticket.mutation {
      if let post = values[id], !tombstones.contains(id) { imported[id] = post }
    }
    values = imported
    var recoveredReactions = Set(baseline.filter { values[$0.postID] != nil })
    for (reaction, counter) in reactionMutations where counter > ticket.mutation {
      if reactionChanges[reaction] == true {
        recoveredReactions.insert(reaction)
      } else {
        recoveredReactions.remove(reaction)
      }
    }
    reactions = recoveredReactions
    publish()
    // Historical posts are never future notification candidates on duplicate delivery.
    for post in posts { rememberNotification(post.id) }
    self.checkpoint = checkpoint
    return true
  }

  /// Returns true when membership/channel metadata requires authoritative REST refresh.
  @discardableResult func apply(
    _ event: WebSocketEvent, origin: SynchronizationOrigin, userID: String, now: Date = Date()
  ) throws -> Bool {
    guard let name = event.event else { return false }
    switch name {
    case "posted", "post_edited", "post_deleted":
      let post = try event.embedded(event.data?.post, as: MattermostPost.self)
      guard !post.id.isEmpty, !post.channelID.isEmpty else {
        throw WebSocketFailure.malformedMessage
      }
      if name == "posted", !notified.contains(post.id) {
        rememberNotification(post.id)
        if origin == .live, post.userID != userID, let mentions = event.data?.mentions,
          let ids = try? JSONDecoder().decode([String].self, from: Data(mentions.utf8)),
          ids.contains(userID)
        {
          mentionPostIDs.append(post.id)
          mentionPostIDs = Array(mentionPostIDs.suffix(100))
          notificationRevision &+= 1
        }
      }
      guard post.channelID == selectedChannelID else { return false }
      if name == "post_deleted" || post.deleteAt > 0 {
        guard tombstones.count < 2_000 || tombstones.contains(post.id) else {
          throw WebSocketFailure.capacityExceeded
        }
        tombstones.insert(post.id)
        rememberNotification(post.id)
        values[post.id] = nil
      } else if !tombstones.contains(post.id) {
        if let previous = values[post.id], previous.updateAt > post.updateAt { return false }
        values[post.id] = post
      }
      mutationCounter &+= 1
      mutations[post.id] = mutationCounter
      guard mutations.count <= 2_000 else { throw WebSocketFailure.capacityExceeded }
      publish()
    case "status_change":
      if let id = event.data?.userID, let status = event.data?.status {
        if statuses.count >= 256 { statuses.removeAll() }
        statuses[id] = status
      }
    case "typing":
      expireTyping(now: now)
      if event.broadcast?.channelID == selectedChannelID,
        let id = event.data?.userID, id != userID
      {
        if typing.count >= 100 { typing.removeAll() }
        typing[id] = now.addingTimeInterval(8)
      }
    case "reaction_added", "reaction_removed":
      let reaction = try event.embedded(event.data?.reaction, as: MattermostReaction.self)
      if values[reaction.postID] != nil {
        guard reactionChanges.count < 2_000 || reactionChanges[reaction] != nil else {
          throw WebSocketFailure.capacityExceeded
        }
        reactionChanges[reaction] = name == "reaction_added"
        mutationCounter &+= 1
        reactionMutations[reaction] = mutationCounter
        if name == "reaction_added" {
          reactions.insert(reaction)
        } else {
          reactions.remove(reaction)
        }
      }
    case "channel_viewed", "multiple_channels_viewed", "post_unread", "thread_read_changed",
      "persistent_notification_triggered", "preferences_changed", "preference_changed":
      if origin == .live { notificationRevision &+= 1 }
    case "channel_created", "channel_updated", "channel_deleted", "channel_restored",
      "channel_converted", "channel_member_updated", "user_added", "user_removed",
      "direct_added", "group_added", "added_to_team", "leave_team", "update_team", "delete_team":
      return true
    default: break
    }
    return false
  }

  func expireTyping(now: Date = Date()) {
    typing = typing.filter { $0.value > now }
  }

  func beginRecovery() {
    statuses = [:]
    typing = [:]
  }

  private func rememberNotification(_ id: String) {
    if notified.count >= 2_000 { notified.removeAll() }
    notified.insert(id)
  }

  private func publish() {
    posts = Array(
      values.values.sorted { ($0.createAt, $0.id) > ($1.createAt, $1.id) }.prefix(200)
    ).reversed()
    values = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
    reactionChanges = reactionChanges.filter { values[$0.key.postID] != nil }
    reactionMutations = reactionMutations.filter { values[$0.key.postID] != nil }
    reactions = reactions.filter { values[$0.postID] != nil }
  }
}
