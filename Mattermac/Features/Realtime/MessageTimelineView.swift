import MattermacCore
import SwiftUI

struct MessageTimelineView: View {
  let realtime: RealtimeSession
  @State private var anchor: String?
  @State private var nearBottom = true
  @State private var unseen = 0
  @State private var initialized = false
  @State private var scrolling = false
  @State private var readerID = UUID()

  private var posts: [MattermostPost] { realtime.synchronization.posts }

  var body: some View {
    VStack(spacing: 8) {
      if let error = realtime.historyMessage {
        HStack {
          Text(error)
          Button("Retry") { realtime.loadOlderMessages() }
        }
        .font(.callout).foregroundStyle(.secondary)
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if !posts.isEmpty {
              HStack {
                Spacer()
                if realtime.isLoadingHistory {
                  ProgressView("Loading older messages…").controlSize(.small)
                } else if realtime.hasOlderMessages {
                  Button("Load older messages") { realtime.loadOlderMessages() }
                    .disabled(realtime.state != .connected)
                } else {
                  Text("Beginning of conversation").foregroundStyle(.secondary)
                }
                Spacer()
              }
              .padding()
            }
            ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
              MessageRowView(
                post: post,
                grouped: MessagePresentation.groups(
                  post, after: index > 0 ? posts[index - 1] : nil),
                author: realtime.authors[post.userID], avatar: realtime.avatars[post.userID],
                reactions: realtime.synchronization.reactions.filter { $0.postID == post.id }
              )
              .id(post.id)
              .task(id: "\(post.userID)-\(realtime.state == .connected)") {
                await realtime.loadAuthor(post.userID)
              }
            }
            Color.clear.frame(height: 1).id("timeline-bottom")
          }
          .scrollTargetLayout()
        }
        .scrollPosition(id: $anchor, anchor: .top)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.contentSize.height - geometry.visibleRect.maxY < 100
        } action: { _, value in
          nearBottom = value
          realtime.synchronization.followLatest(value, reader: readerID)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.visibleRect.minY < 80
        } action: { _, value in
          if value, scrolling, initialized, realtime.historyMessage == nil {
            realtime.loadOlderMessages()
          }
        }
        .onChange(of: posts.last?.id, initial: true) { _, _ in
          if !initialized, !posts.isEmpty {
            initialized = true
            proxy.scrollTo("timeline-bottom", anchor: .bottom)
          } else if nearBottom, !realtime.synchronization.isBrowsingHistory {
            proxy.scrollTo("timeline-bottom", anchor: .bottom)
          }
        }
        .onChange(of: realtime.synchronization.arrivalRevision) { _, _ in
          if !nearBottom || realtime.synchronization.isBrowsingHistory { unseen += 1 }
        }
        .overlay {
          if posts.isEmpty {
            if realtime.state == .connecting || realtime.state == .synchronizing {
              ProgressView("Loading messages…")
            } else {
              ContentUnavailableView(
                "No messages", systemImage: "bubble.left.and.bubble.right",
                description: Text("Reconnect to retry if messages could not be loaded."))
            }
          }
        }
      }
      if unseen > 0 || realtime.synchronization.isBrowsingHistory
        || realtime.synchronization.hasDeferredMessages
      {
        Button(unseen > 0 ? "\(unseen) new messages · Latest messages" : "Latest messages") {
          unseen = 0
          initialized = false
          nearBottom = true
          realtime.showRecentMessages()
        }
      }
      if !realtime.synchronization.typing.isEmpty {
        Text("Someone is typing…").font(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityLabel("Channel message history")
    .onDisappear { realtime.synchronization.followLatest(true, reader: readerID) }
  }
}
