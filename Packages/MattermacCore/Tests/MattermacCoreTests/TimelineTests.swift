import Foundation
import Testing

@testable import MattermacCore

private func timelinePost(_ index: Int, revision: Int64 = 1) -> MattermostPost {
  MattermostPost(
    id: String(format: "p%05d", index), userID: "synthetic", channelID: "timeline", rootID: "",
    message: "Synthetic **message** @someone `code`", createAt: Int64(index),
    updateAt: revision, deleteAt: 0, hasReactions: false)
}

private func timelinePage(_ range: Range<Int>) -> ChannelPosts {
  let posts = range.map { timelinePost($0) }
  return ChannelPosts(
    order: posts.map(\.id), posts: Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) }))
}

@MainActor private func timelineCoordinator() -> SynchronizationCoordinator {
  let coordinator = SynchronizationCoordinator()
  coordinator.setChannels([
    MattermostChannel(
      id: "timeline", teamID: "team", name: "timeline", displayName: "Timeline", type: "O")
  ])
  return coordinator
}

private func timelineEvent(_ name: String, post: MattermostPost) throws -> WebSocketEvent {
  let json = String(decoding: try JSONEncoder().encode(post), as: UTF8.self)
  return try WebSocketEvent.decode(
    JSONSerialization.data(withJSONObject: [
      "event": name, "data": ["post": json], "broadcast": ["channel_id": "timeline"],
    ]))
}

@Test @MainActor func timelineTraversesTenThousandPostsWithBoundedWindow() throws {
  let coordinator = timelineCoordinator()
  coordinator.commit(timelinePage(9_800..<10_000), ticket: try #require(coordinator.beginImport()))
  #expect(coordinator.posts.count == 200)
  for end in stride(from: 9_800, through: 100, by: -100) {
    let ticket = try #require(coordinator.beginImport())
    #expect(coordinator.prepend(timelinePage((end - 100)..<end), ticket: ticket))
    #expect(coordinator.posts.count <= 400)
    #expect(coordinator.posts.first?.id == timelinePost(end - 100).id)
    #expect(Set(coordinator.posts.map(\.id)).count == coordinator.posts.count)
  }
  #expect(coordinator.posts.last?.id == timelinePost(399).id)
  #expect(coordinator.mentionPostIDs.isEmpty)
}

@Test @MainActor func historyImportRetainsConcurrentEditsDeletesAndRejectsStaleWindow() throws {
  let coordinator = timelineCoordinator()
  coordinator.commit(timelinePage(100..<200), ticket: try #require(coordinator.beginImport()))
  let ticket = try #require(coordinator.beginImport())
  try coordinator.apply(
    timelineEvent("post_edited", post: timelinePost(120, revision: 30)), origin: .live, userID: "me"
  )
  try coordinator.apply(
    timelineEvent("post_deleted", post: timelinePost(130, revision: 40)), origin: .live,
    userID: "me")
  coordinator.prepend(timelinePage(0..<150), ticket: ticket)
  #expect(coordinator.posts.first { $0.id == timelinePost(120).id }?.updateAt == 30)
  #expect(!coordinator.posts.contains { $0.id == timelinePost(130).id })
  coordinator.resetWindow()
  #expect(!coordinator.prepend(timelinePage(0..<100), ticket: ticket))
}

@Test @MainActor func arrivalsDoNotDisplaceReaderAndDuplicatesDoNotCountTwice() throws {
  let coordinator = timelineCoordinator()
  coordinator.commit(timelinePage(0..<200), ticket: try #require(coordinator.beginImport()))
  let reader = UUID()
  coordinator.followLatest(false, reader: reader)
  let incoming = try timelineEvent("posted", post: timelinePost(200))
  try coordinator.apply(incoming, origin: .live, userID: "me")
  try coordinator.apply(incoming, origin: .live, userID: "me")
  #expect(coordinator.arrivalRevision == 1)
  #expect(coordinator.posts.first?.id == timelinePost(0).id)
  #expect(coordinator.posts.last?.id == timelinePost(199).id)
  coordinator.followLatest(true, reader: reader)
  try coordinator.apply(
    timelineEvent("posted", post: timelinePost(201)), origin: .live, userID: "me")
  #expect(coordinator.posts.last?.id == timelinePost(201).id)
  coordinator.prepend(timelinePage(0..<50), ticket: try #require(coordinator.beginImport()))
  try coordinator.apply(
    timelineEvent("posted", post: timelinePost(202)), origin: .live, userID: "me")
  #expect(coordinator.posts.last?.id == timelinePost(201).id)
}

@Test func markdownBlocksPreserveCodeAndHandleUnclosedAndLongFences() {
  let blocks = MessageBlock.parse(
    "Hello @someone `inline`\n```swift\nlet x = 1\n```\n[site](https://example.com)")
  #expect(blocks.map(\.isCode) == [false, true, false])
  #expect(blocks[1].text == "let x = 1")
  #expect(MessageBlock.parse("~~~\n@literal\n").first?.isCode == true)
  #expect(MessageBlock.parse("````\n```\n````").first?.text == "```")
  #expect(MessageBlock.parse("").first?.text == "")
  for address in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "mattermac:run"]
  {
    #expect(!MessagePresentation.allowsLink(URL(string: address)!))
  }
  for address in ["https://example.com", "http://localhost", "mailto:synthetic@example.com"] {
    #expect(MessagePresentation.allowsLink(URL(string: address)!))
  }
}

@Test func groupingSeparatesAuthorsSystemMessagesAndTimeGaps() {
  let first = timelinePost(1)
  #expect(MessagePresentation.groups(timelinePost(2), after: first))
  #expect(!MessagePresentation.groups(timelinePost(300_001), after: first))
  #expect(!MessagePresentation.groups(first, after: nil))
  var system = timelinePost(2)
  system.type = "system_join_channel"
  #expect(!MessagePresentation.groups(system, after: first))
  #expect(!MessagePresentation.groups(first, after: system))
}
