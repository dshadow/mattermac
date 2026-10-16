import MattermacCore
import SwiftUI

struct RealtimeView: View {
  let realtime: RealtimeSession

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(realtime.state.rawValue)
          .foregroundStyle(realtime.state == .connected ? Color.primary : Color.secondary)
        Spacer()
        Text("Latest 200 messages").foregroundStyle(.secondary)
      }
      Picker(
        "Channel",
        selection: Binding(
          get: { realtime.synchronization.selectedChannelID ?? "" },
          set: { realtime.selectChannel($0) })
      ) {
        ForEach(realtime.synchronization.channels) { channel in
          Text(channel.displayName.isEmpty ? channel.name : channel.displayName).tag(channel.id)
        }
      }
      .disabled(realtime.synchronization.channels.isEmpty)
      if realtime.synchronization.posts.isEmpty {
        ContentUnavailableView(
          "No recent messages", systemImage: "bubble.left.and.bubble.right",
          description: Text("Messages appear here when this channel is connected."))
      } else {
        List(realtime.synchronization.posts) { post in
          VStack(alignment: .leading, spacing: 4) {
            Text(Date(timeIntervalSince1970: Double(post.createAt) / 1_000), style: .time)
              .font(.caption).foregroundStyle(.secondary)
            Text(post.message).textSelection(.enabled)
            let reactions = realtime.synchronization.reactions.filter { $0.postID == post.id }
            if !reactions.isEmpty {
              Text(reactions.map { ":\($0.emojiName):" }.sorted().joined(separator: " "))
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        }
        .accessibilityLabel("Recent channel messages")
      }
      if !realtime.synchronization.typing.isEmpty {
        Text("Someone is typing…").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
