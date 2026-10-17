import Foundation
import Testing

@testable import MattermacCore

private func navigationChannel(type: String = "O", count: Int? = nil) -> MattermostChannel {
  MattermostChannel(
    id: "channel", teamID: "team", name: "me__peer", displayName: "",
    type: type, totalMsgCount: count)
}

@Test func navigationBadgesUseServerCountsAndClampMentions() throws {
  let member = try JSONDecoder().decode(
    NavigationMembership.self,
    from: Data(#"{"channel_id":"channel","msg_count":8,"mention_count":0}"#.utf8))
  #expect(NavigationSnapshot.badge(channel: navigationChannel(count: 9), member: member).unread)
  #expect(!NavigationSnapshot.badge(channel: navigationChannel(count: 8), member: member).unread)
  #expect(!NavigationSnapshot.badge(channel: navigationChannel(count: 7), member: member).unread)
  #expect(!NavigationSnapshot.badge(channel: navigationChannel(), member: member).unread)
  let mention = try JSONDecoder().decode(
    NavigationMembership.self,
    from: Data(#"{"channel_id":"channel","msg_count":8,"mention_count":3}"#.utf8))
  #expect(NavigationSnapshot.badge(channel: navigationChannel(), member: mention).mentions == 3)
  #expect(NavigationSnapshot.badge(channel: navigationChannel(), member: mention).unread)
}

@Test func groupsIncludeEveryChannelExactlyOnce() {
  for type in ["O", "P", "D", "G", "future"] {
    #expect(ChannelGroup.allCases.filter { $0.contains(navigationChannel(type: type)) }.count == 1)
  }
}

@Test func directMessageNamesUsePeerProfilesAndSafeFallbacks() throws {
  var snapshot = NavigationSnapshot()
  let direct = navigationChannel(type: "D")
  #expect(snapshot.title(for: direct, currentUserID: "me") == "Direct message")
  snapshot.users["peer"] = try JSONDecoder().decode(
    MattermostUser.self,
    from: Data(#"{"id":"peer","username":"synthetic-peer"}"#.utf8))
  #expect(snapshot.title(for: direct, currentUserID: "me") == "@synthetic-peer")
  #expect(snapshot.title(for: navigationChannel(), currentUserID: "me") == "me__peer")
}

@Test @MainActor func restartRestoresExplicitSelectionAcrossTeams() async throws {
  var directory = URL(fileURLWithPath: #filePath)
  for _ in 0..<5 { directory.deleteLastPathComponent() }
  directory.appendPathComponent("tmp/navigation-tests/\(UUID().uuidString)")
  let persistence = PersistenceController(directory: directory)
  try await persistence.open()
  let cache = CacheRepository(persistence)
  let teams = [
    MattermostTeam(id: "one", name: "one", displayName: "First"),
    MattermostTeam(id: "two", name: "two", displayName: "Second"),
  ]
  let user = try JSONDecoder().decode(
    MattermostUser.self,
    from: Data(#"{"id":"me","username":"synthetic"}"#.utf8))
  try await cache.saveIdentity(user, teams: teams)
  try await cache.replaceChannels([
    MattermostChannel(id: "a", teamID: "one", name: "first", displayName: "First", type: "O"),
    MattermostChannel(id: "b", teamID: "two", name: "second", displayName: "Second", type: "P"),
  ])
  try await cache.selectChannel("b")
  try await persistence.close()
  let reopened = PersistenceController(directory: directory)
  try await reopened.open()
  let restored = CacheRepository(reopened)
  let coordinator = SynchronizationCoordinator()
  coordinator.restore(try await restored.snapshot())
  #expect(coordinator.selectedChannelID == "b")
  #expect(coordinator.channels.first { $0.id == coordinator.selectedChannelID }?.teamID == "two")
  #expect(try await restored.teams().count == 2)
  try await reopened.close(removeFiles: true)
}
