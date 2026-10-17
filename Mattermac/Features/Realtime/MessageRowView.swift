import AppKit
import ImageIO
import MattermacCore
import SwiftUI

struct MessageRowView: View {
  let post: MattermostPost
  let grouped: Bool
  let author: MattermostUser?
  let avatar: Data?
  let reactions: Set<MattermostReaction>

  private var date: Date { Date(timeIntervalSince1970: Double(post.createAt) / 1_000) }
  private var name: String {
    guard let author else { return "Unknown author" }
    let full = [author.firstName, author.lastName].compactMap { $0 }
      .filter { !$0.isEmpty }.joined(separator: " ")
    return full.isEmpty ? "@\(author.username)" : full
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Group {
        if post.isSystem {
          Image(systemName: "info.circle").foregroundStyle(.secondary)
        } else if !grouped {
          if let avatar, let image = thumbnail(avatar) {
            Image(nsImage: image).resizable().scaledToFill()
          } else {
            Image(systemName: "person.crop.circle.fill").resizable()
              .foregroundStyle(.secondary)
          }
        } else {
          Color.clear
        }
      }
      .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          if !grouped { Text(post.isSystem ? "System" : name).fontWeight(.semibold) }
          Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
            .font(.caption).foregroundStyle(.secondary)
          if (post.editAt ?? 0) > 0 {
            Text("edited").font(.caption).foregroundStyle(.secondary)
          }
        }
        MessageTextView(message: post.message)
          .foregroundStyle(post.isSystem ? .secondary : .primary)
        if !reactions.isEmpty {
          Text(reactions.map { ":\($0.emojiName):" }.sorted().joined(separator: " "))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 8).padding(.top, grouped ? 4 : 14).padding(.bottom, 4)
    .accessibilityElement(children: .combine)
  }

  private func thumbnail(_ data: Data) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 64,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: 32, height: 32))
  }
}
