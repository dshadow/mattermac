import Foundation

/// Decode only supported payloads; unknown event data is discarded, not retained or logged.
public struct WebSocketEvent: Decodable, Sendable {
  public let event: String?
  public let sequence: Int64?
  public let replySequence: Int64?
  public let status: String?
  public let data: Payload?
  public let broadcast: Broadcast?

  public struct Broadcast: Decodable, Sendable {
    public let channelID: String?
    enum CodingKeys: String, CodingKey { case channelID = "channel_id" }
  }

  public struct Payload: Decodable, Sendable {
    public let post: String?
    public let reaction: String?
    public let userID: String?
    public let channelID: String?
    public let status: String?
    public let mentions: String?
    public let postID: String?

    enum CodingKeys: String, CodingKey {
      case post, reaction, status, mentions
      case userID = "user_id"
      case channelID = "channel_id"
      case postID = "post_id"
    }
  }

  enum CodingKeys: String, CodingKey {
    case event, status, data, broadcast
    case sequence = "seq"
    case replySequence = "seq_reply"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    event = try container.decodeIfPresent(String.self, forKey: .event)
    sequence = try container.decodeIfPresent(Int64.self, forKey: .sequence)
    replySequence = try container.decodeIfPresent(Int64.self, forKey: .replySequence)
    status = try container.decodeIfPresent(String.self, forKey: .status)
    broadcast = try? container.decodeIfPresent(Broadcast.self, forKey: .broadcast)
    // Plugin/future events may reuse field names with incompatible types. Skip their data.
    let supported = [
      "posted", "post_edited", "post_deleted", "status_change", "typing",
      "reaction_added", "reaction_removed",
    ]
    data =
      supported.contains(event ?? "")
      ? try container.decodeIfPresent(Payload.self, forKey: .data) : nil
  }

  public static func decode(_ bytes: Data) throws -> WebSocketEvent {
    guard bytes.count <= 1_048_576 else { throw WebSocketFailure.capacityExceeded }
    do { return try JSONDecoder().decode(Self.self, from: bytes) } catch {
      throw WebSocketFailure.malformedMessage
    }
  }

  func embedded<Value: Decodable>(_ value: String?, as: Value.Type) throws -> Value {
    guard let value else { throw WebSocketFailure.malformedMessage }
    do { return try JSONDecoder().decode(Value.self, from: Data(value.utf8)) } catch {
      throw WebSocketFailure.malformedMessage
    }
  }
}

struct WebSocketSequence {
  private var next: Int64 = 0
  mutating func accept(_ event: WebSocketEvent) throws -> Bool {
    // Action replies have a separate client sequence; they never advance server sequence.
    guard event.event != nil else { return false }
    guard let sequence = event.sequence, sequence >= 0, sequence < Int64.max else {
      throw WebSocketFailure.malformedMessage
    }
    if sequence < next { return false }
    guard sequence == next else { throw WebSocketFailure.sequenceGap }
    next += 1
    return true
  }
}

public enum WebSocketAuthentication: Sendable { case bearerHeader, challenge }

struct AuthenticationChallenge: Encodable {
  let seq = 1
  let action = "authentication_challenge"
  let data: TokenData
  struct TokenData: Encodable { let token: String }
}

public struct WebSocketBackoff: Sendable {
  public init() {}
  public func delay(attempt: Int, randomUnit: Double = Double.random(in: 0...1)) -> TimeInterval {
    // Equal jitter: never tight-loop, never exceed 30 seconds.
    let ceiling = min(30, pow(2, Double(max(0, min(attempt, 5)))))
    return ceiling * (0.5 + 0.5 * min(1, max(0, randomUnit)))
  }
}
