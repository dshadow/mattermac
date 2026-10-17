import Foundation

public enum MessagePresentation {
  public static func groups(_ post: MattermostPost, after previous: MattermostPost?) -> Bool {
    guard let previous, !post.isSystem, !previous.isSystem,
      previous.userID == post.userID, previous.channelID == post.channelID,
      post.createAt >= previous.createAt, post.createAt - previous.createAt < 300_000
    else { return false }
    return Calendar.current.isDate(
      Date(timeIntervalSince1970: Double(post.createAt) / 1_000),
      inSameDayAs: Date(timeIntervalSince1970: Double(previous.createAt) / 1_000))
  }

  public static func allowsLink(_ url: URL) -> Bool {
    ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
  }
}

/// Small shared Markdown block model. Raw HTML and remote images are never loaded.
public struct MessageBlock: Equatable, Sendable {
  public let text: String
  public let isCode: Bool

  public static func parse(_ message: String) -> [Self] {
    var blocks: [Self] = []
    var lines: [String] = []
    var fence: String?
    func flush(code: Bool) {
      if !lines.isEmpty { blocks.append(Self(text: lines.joined(separator: "\n"), isCode: code)) }
      lines = []
    }
    for line in message.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let active = fence {
        if trimmed.hasPrefix(active),
          trimmed.dropFirst(active.count).allSatisfy({ $0 == active.first })
        {
          flush(code: true)
          fence = nil
        } else {
          lines.append(line)
        }
      } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        flush(code: false)
        let character = trimmed.first!
        fence = String(trimmed.prefix(while: { $0 == character }))
      } else {
        lines.append(line)
      }
    }
    flush(code: fence != nil)
    return blocks
  }
}
