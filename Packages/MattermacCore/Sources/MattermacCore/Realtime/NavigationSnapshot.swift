import Foundation

public struct NavigationMembership: Decodable, Sendable {
  public let channelID: String
  public let msgCount: Int
  public let mentionCount: Int

  enum CodingKeys: String, CodingKey {
    case channelID = "channel_id"
    case msgCount = "msg_count"
    case mentionCount = "mention_count"
  }
}

/// Server read state only: navigating does not acknowledge a read or fabricate local counts.
public struct NavigationBadge: Sendable, Equatable {
  public let unread: Bool
  public let mentions: Int
}

public enum ChannelGroup: String, CaseIterable, Sendable {
  case channels = "Channels"
  case privateChannels = "Private Channels"
  case directMessages = "Direct Messages"
  case groupMessages = "Group Messages"
  case other = "Other Channels"

  public func contains(_ channel: MattermostChannel) -> Bool {
    switch self {
    case .channels: channel.type == "O"
    case .privateChannels: channel.type == "P"
    case .directMessages: channel.type == "D"
    case .groupMessages: channel.type == "G"
    case .other: !["O", "P", "D", "G"].contains(channel.type)
    }
  }
}

public struct NavigationSnapshot: Sendable {
  public var teams: [MattermostTeam] = []
  public var users: [String: MattermostUser] = [:]
  public var badges: [String: NavigationBadge] = [:]

  public init() {}

  public func title(for channel: MattermostChannel, currentUserID: String) -> String {
    if channel.type == "D" {
      let peer =
        channel.name.components(separatedBy: "__").first { $0 != currentUserID }
        ?? currentUserID
      if let user = users[peer] { return "@" + user.username }
      return channel.displayName.isEmpty ? "Direct message" : channel.displayName
    }
    return channel.displayName.isEmpty ? channel.name : channel.displayName
  }

  public static func badge(channel: MattermostChannel, member: NavigationMembership)
    -> NavigationBadge
  {
    NavigationBadge(
      unread: (channel.totalMsgCount.map { $0 > member.msgCount } ?? false)
        || member.mentionCount > 0,
      mentions: max(0, member.mentionCount))
  }
}
