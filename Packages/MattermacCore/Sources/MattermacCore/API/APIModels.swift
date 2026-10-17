import Foundation

/// A bearer token remains in memory; persistence belongs to the authentication layer.
public struct SessionToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let value: String

  public init(_ value: String) throws {
    guard !value.isEmpty, value.utf8.allSatisfy({ (33...126).contains($0) }) else {
      throw APIError.invalidCredentials
    }
    self.value = value
  }

  public var description: String { "SessionToken(<redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct LoginCredentials: Encodable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private let loginID: String
  private let password: String
  private let token: String?

  public init(loginID: String, password: String, mfaCode: String? = nil) throws {
    guard !loginID.isEmpty, !password.isEmpty else { throw APIError.invalidCredentials }
    self.loginID = loginID
    self.password = password
    token = mfaCode
  }

  enum CodingKeys: String, CodingKey {
    case loginID = "login_id"
    case password, token
  }

  public var description: String { "LoginCredentials(<redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct LoginSession: Sendable {
  public let user: MattermostUser
  public let token: SessionToken
}

// Decode only fields used by the initial navigation and messaging slice.
public struct MattermostUser: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let username: String
  public let firstName: String?
  public let lastName: String?
  public let mfaActive: Bool?

  enum CodingKeys: String, CodingKey {
    case id, username
    case firstName = "first_name"
    case lastName = "last_name"
    case mfaActive = "mfa_active"
  }
}

public struct MattermostTeam: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let displayName: String

  enum CodingKeys: String, CodingKey {
    case id, name
    case displayName = "display_name"
  }
}

public struct MattermostChannel: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let teamID: String
  public let name: String
  public let displayName: String
  /// Keep unknown future channel types decodable.
  public let type: String
  public var totalMsgCount: Int? = nil

  enum CodingKeys: String, CodingKey {
    case id, name, type
    case teamID = "team_id"
    case displayName = "display_name"
    case totalMsgCount = "total_msg_count"
  }
}

public struct MattermostPost: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let userID: String
  public let channelID: String
  public let rootID: String
  public let message: String
  /// Mattermost timestamps use milliseconds since the Unix epoch.
  public let createAt: Int64
  public let updateAt: Int64
  public let deleteAt: Int64
  public let hasReactions: Bool?
  public var type: String? = nil
  public var editAt: Int64? = nil

  public var isSystem: Bool { type?.hasPrefix("system_") == true }

  public init(
    id: String, userID: String, channelID: String, rootID: String, message: String,
    createAt: Int64, updateAt: Int64, deleteAt: Int64, hasReactions: Bool?,
    type: String? = nil, editAt: Int64? = nil
  ) {
    self.id = id
    self.userID = userID
    self.channelID = channelID
    self.rootID = rootID
    self.message = message
    self.createAt = createAt
    self.updateAt = updateAt
    self.deleteAt = deleteAt
    self.hasReactions = hasReactions
    self.type = type
    self.editAt = editAt
  }

  enum CodingKeys: String, CodingKey {
    case id, message, type
    case editAt = "edit_at"
    case userID = "user_id"
    case channelID = "channel_id"
    case rootID = "root_id"
    case createAt = "create_at"
    case updateAt = "update_at"
    case deleteAt = "delete_at"
    case hasReactions = "has_reactions"
  }
}

public struct ChannelPosts: Decodable, Sendable, Equatable {
  public let order: [String]
  public let posts: [String: MattermostPost]

  /// Dictionary iteration does not preserve the server's timeline order.
  public var orderedPosts: [MattermostPost] { order.compactMap { posts[$0] } }
}

public struct CreatePost: Encodable, Sendable {
  public let channelID: String
  public let message: String
  public let rootID: String?

  public init(channelID: String, message: String, rootID: String? = nil) {
    self.channelID = channelID
    self.message = message
    self.rootID = rootID
  }

  enum CodingKeys: String, CodingKey {
    case message
    case channelID = "channel_id"
    case rootID = "root_id"
  }
}
