import CoreData
import Foundation
import Testing

@testable import MattermacCore

private func storageDirectory() -> URL {
  var root = URL(fileURLWithPath: #filePath)
  for _ in 0..<5 { root.deleteLastPathComponent() }
  return root.appendingPathComponent("tmp/persistence-tests/\(UUID().uuidString)")
}

private func cachedChannel(_ id: String = "channel") -> MattermostChannel {
  MattermostChannel(id: id, teamID: "team", name: id, displayName: id, type: "O")
}

private func cachedPost(
  _ id: String, revision: Int64 = 1, root: String = "",
  deleted: Int64 = 0, channel: String = "channel"
) -> MattermostPost {
  MattermostPost(
    id: id, userID: "user", channelID: channel, rootID: root,
    message: "synthetic \(revision)", createAt: 100, updateAt: revision,
    deleteAt: deleted, hasReactions: false)
}

private func cacheAt(_ url: URL, version: Int = 2) async throws -> CacheRepository {
  let persistence = PersistenceController(directory: url, version: version)
  try await persistence.open()
  return CacheRepository(persistence)
}

@Test func sqliteRestartPreservesTypedSnapshotsAndSeparateAccountPaths() async throws {
  let directory = storageDirectory()
  let cache = try await cacheAt(directory)
  try await cache.replaceChannels([cachedChannel()])
  try await cache.selectChannel("channel")
  let post = cachedPost("root")
  try await cache.importPosts([post, cachedPost("reply", root: "root")], channelID: "channel")
  let state = ChannelReadState(channelID: "channel", lastViewedAt: 100, mentionCount: 2)
  try await cache.saveReadState(state)
  try await cache.persistence.close()
  let restored = try await cacheAt(directory)
  let snapshot = try await restored.snapshot()
  #expect(snapshot.selectedChannelID == "channel")
  #expect(snapshot.posts.count == 2)
  #expect(try await restored.posts(channelID: "channel", rootID: "root").posts.count == 2)
  #expect(try await restored.readState(channelID: "channel") == state)
  #expect(try await restored.checkpoint(channelID: "channel") != nil)
  let account = SessionAccount(serverAddress: "https://example.com", userID: "one/../../")
  let other = SessionAccount(serverAddress: "https://example.com", userID: "two")
  #expect(
    PersistenceController.accountDirectory(root: directory, account: account)
      != PersistenceController.accountDirectory(root: directory, account: other))
  try await restored.persistence.close(removeFiles: true)
}

@Test func cursorPaginationHasNoGapsWithIdenticalTimestampsAndEdits() async throws {
  let cache = try await cacheAt(storageDirectory())
  try await cache.replaceChannels([cachedChannel()])
  for batch in 0..<3 {
    let posts = (0..<200).map { cachedPost(String(format: "%04d", batch * 200 + $0)) }
    try await cache.importPosts(posts, channelID: "channel")
  }
  var ids: [String] = []
  var cursor: PostCursor?
  repeat {
    let page = try await cache.posts(channelID: "channel", before: cursor, limit: 73)
    ids += page.posts.map(\.id)
    cursor = page.next
    if ids.count == 73 {
      try await cache.importPosts([cachedPost("0001", revision: 9)], channelID: "channel")
    }
  } while cursor != nil
  #expect(ids.count == 600)
  #expect(Set(ids).count == 600)
  #expect(ids == ids.sorted(by: >))
  #expect(try await cache.posts(channelID: "channel", limit: 99_999).posts.count == 200)
  try await cache.persistence.close(removeFiles: true)
}

@Test func durableRevisionsAndTombstonesRejectStaleHistoryAfterRestart() async throws {
  let directory = storageDirectory()
  var cache = try await cacheAt(directory)
  try await cache.replaceChannels([cachedChannel()])
  let ticket = try await cache.beginImport()
  try await cache.importPosts(
    [cachedPost("edited", revision: 30), cachedPost("deleted", revision: 20)], channelID: "channel",
    deletedIDs: ["deleted"])
  try await cache.importPosts(
    [cachedPost("edited"), cachedPost("deleted", revision: 100)], channelID: "channel",
    ticket: ticket)
  #expect(try await cache.post(id: "edited")?.updateAt == 30)
  #expect(try await cache.post(id: "deleted") == nil)
  try await cache.persistence.close()
  cache = try await cacheAt(directory)
  try await cache.importPosts([cachedPost("deleted", revision: 200)], channelID: "channel")
  #expect(try await cache.post(id: "deleted") == nil)
  let checkpoint = UUID()
  try await cache.importPosts(
    [], channelID: "channel", checkpoint: checkpoint,
    authoritativeWindow: ["edited"], ticket: try await cache.beginImport())
  #expect(try await cache.posts(channelID: "channel").posts.isEmpty)
  #expect(try await cache.checkpoint(channelID: "channel") == checkpoint)
  try await cache.persistence.close(removeFiles: true)
}

@Test func interruptedUnitRollsBackDataAndCheckpointTogether() async throws {
  let cache = try await cacheAt(storageDirectory())
  try await cache.replaceChannels([cachedChannel()])
  let checkpoint = UUID()
  try await cache.importPosts([cachedPost("one")], channelID: "channel", checkpoint: checkpoint)
  await #expect(throws: PersistenceError.self) {
    try await cache.persistence.transaction { context, _ in
      try Records.put(context, kind: "checkpoint", id: "channel", value: UUID(), now: Date())
      try Records.put(context, kind: "post", id: "two", value: cachedPost("two"), now: Date())
      throw PersistenceError.invalidData
    } as Void
  }
  #expect(try await cache.checkpoint(channelID: "channel") == checkpoint)
  #expect(try await cache.post(id: "two") == nil)
  try await cache.persistence.close(removeFiles: true)
}

@Test func lightweightMigrationPreservesCacheAndDurableOutgoing() async throws {
  let directory = storageDirectory()
  let old = try await cacheAt(directory.appendingPathComponent("Cache"), version: 1)
  try await old.replaceChannels([cachedChannel()])
  try await old.importPosts([cachedPost("one")], channelID: "channel")
  try await old.persistence.close()
  let migrated = try await cacheAt(directory.appendingPathComponent("Cache"))
  #expect(try await migrated.posts(channelID: "channel").posts.count == 1)
  let oldDurable = PersistenceController(
    directory: directory.appendingPathComponent("Outgoing"), durable: true, version: 1)
  try await oldDurable.open()
  let message = OutgoingMessage(channelID: "channel", message: "unsent", state: .uncertain)
  try await OutgoingRepository(oldDurable).save(message)
  try await oldDurable.close()
  let newDurable = PersistenceController(
    directory: directory.appendingPathComponent("Outgoing"), durable: true)
  try await newDurable.open()
  #expect(try await OutgoingRepository(newDurable).messages() == [message])
  try await migrated.persistence.close(removeFiles: true)
  try await newDurable.close(removeFiles: true)
}

@Test @MainActor func cacheRebuildAndRetentionPreserveDraftsAndPendingSends() async throws {
  let root = storageDirectory()
  let preferences = UserDefaults(suiteName: "PersistenceTests-\(UUID().uuidString)")!
  let account = SessionAccount(serverAddress: "https://example.com", userID: "one")
  let storage = AccountPersistence(root: root, preferences: preferences)
  try await storage.reconcile(for: account)
  let draft = OutgoingMessage(channelID: "channel", message: "draft")
  let pending = OutgoingMessage(channelID: "channel", message: "pending", state: .uncertain)
  try await storage.saveOutgoing(draft)
  try await storage.saveOutgoing(pending)
  let cache = try #require(storage.cache)
  try await cache.replaceChannels([cachedChannel()])
  try await cache.importPosts([cachedPost("one")], channelID: "channel", now: .distantPast)
  try await cache.evict(retentionDays: 30, activeChannelID: "channel")
  #expect(try await cache.post(id: "one") != nil)
  try await cache.evict(retentionDays: 30)
  #expect(try await cache.posts(channelID: "channel").posts.isEmpty)
  #expect(storage.hasUnsentContent(for: account))
  storage.pause(for: account)
  await #expect(throws: PersistenceError.self) { try await storage.saveOutgoing(draft) }
  // Remove disposable schema and replace it with malformed data; durable files stay intact.
  try await cache.persistence.close(removeFiles: true)
  let cacheDirectory = PersistenceController.accountDirectory(root: root, account: account)
    .appendingPathComponent("Cache")
  try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
  try Data("invalid sqlite".utf8).write(to: cacheDirectory.appendingPathComponent("store.sqlite"))
  let restarted = AccountPersistence(root: root, preferences: preferences)
  try await restarted.reconcile(for: account)
  #expect(restarted.notice != nil)
  #expect(Set(try await restarted.outgoingMessages().map(\.id)) == [draft.id, pending.id])
  try await restarted.clear(for: account)
  try await storage.clear(for: account)
  #expect(!FileManager.default.fileExists(atPath: cacheDirectory.deletingLastPathComponent().path))
}

@Test func permissionRevocationPurgesChannelAndFencesClosedHandles() async throws {
  let directory = storageDirectory()
  let cache = try await cacheAt(directory)
  try await cache.replaceChannels([cachedChannel(), cachedChannel("private")])
  try await cache.importPosts([cachedPost("one", channel: "private")], channelID: "private")
  try await cache.replaceChannels([cachedChannel()])
  #expect(try await cache.posts(channelID: "private").posts.isEmpty)
  try await cache.importPosts([cachedPost("one", channel: "private")], channelID: "private")
  #expect(try await cache.post(id: "one") == nil)
  try await cache.persistence.close(removeFiles: true)
  await #expect(throws: PersistenceError.self) {
    try await cache.replaceChannels([cachedChannel()])
  }
  #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test @MainActor func memoryCacheEnforcesCostAndLRU() {
  let cache = BoundedMemoryCache<String>(limit: 10)
  cache.insert("one", for: "one", cost: 5)
  cache.insert("two", for: "two", cost: 5)
  #expect(cache.value(for: "one") == "one")
  cache.insert("three", for: "three", cost: 5)
  #expect(cache.value(for: "two") == nil)
  cache.insert("huge", for: "huge", cost: 11)
  #expect(cache.value(for: "huge") == nil)
  #expect(cache.totalCost == 10)
  cache.removeAll()
  #expect(cache.totalCost == 0)
}

@Test func fullRecentPageDoesNotTurnDisplacedHistoryIntoDeletions() async throws {
  let cache = try await cacheAt(storageDirectory())
  try await cache.replaceChannels([cachedChannel()])
  let older = (0..<200).map { cachedPost(String(format: "%04d", $0)) }
  let newer = (200..<400).map { cachedPost(String(format: "%04d", $0)) }
  try await cache.importPosts(older, channelID: "channel")
  try await cache.importPosts(
    newer, channelID: "channel",
    authoritativeWindow: Set(older.map(\.id)), ticket: try await cache.beginImport())
  #expect(try await cache.post(id: "0001") != nil)
  #expect(try await cache.recentPosts(channelID: "channel").map(\.id) == newer.map(\.id).reversed())
  try await cache.importPosts(
    [], channelID: "channel",
    authoritativeWindow: Set(newer.map(\.id)), ticket: try await cache.beginImport())
  #expect(try await cache.recentPosts(channelID: "channel").isEmpty)
  try await cache.persistence.close(removeFiles: true)
}

@Test @MainActor func damagedOutgoingStoreBlocksActivationWithoutDiscardingBytes() async throws {
  let root = storageDirectory()
  let account = SessionAccount(serverAddress: "https://example.com", userID: "one")
  let directory = PersistenceController.accountDirectory(root: root, account: account)
    .appendingPathComponent("Outgoing")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let bytes = Data("damaged durable store; preserve for recovery".utf8)
  let file = directory.appendingPathComponent("store.sqlite")
  try bytes.write(to: file)
  let storage = AccountPersistence(root: root)
  await #expect(throws: PersistenceError.self) { try await storage.reconcile(for: account) }
  #expect(try Data(contentsOf: file) == bytes)
  #expect(storage.cache == nil)
  #expect(storage.hasUnsentContent(for: account))
  try await storage.clear(for: account)
}

@Test func newerDurableSchemaIsRefusedWithoutDowngrading() async throws {
  let directory = storageDirectory()
  let future = PersistenceController(directory: directory, durable: true, version: 3)
  try await future.open()
  let draft = OutgoingMessage(channelID: "channel", message: "future draft")
  try await OutgoingRepository(future).save(draft)
  try await future.close()
  let older = PersistenceController(directory: directory, durable: true)
  await #expect(throws: PersistenceError.self) { try await older.open() }
  let reopened = PersistenceController(directory: directory, durable: true, version: 3)
  try await reopened.open()
  #expect(try await OutgoingRepository(reopened).messages() == [draft])
  try await reopened.close(removeFiles: true)
}

@Test @MainActor func accountSwitchCannotExposeOtherAccountsDraftsOrPosts() async throws {
  let storage = AccountPersistence(root: storageDirectory())
  let one = SessionAccount(serverAddress: "https://example.com", userID: "one")
  let two = SessionAccount(serverAddress: "https://example.com", userID: "two")
  try await storage.reconcile(for: one)
  let draft = OutgoingMessage(channelID: "channel", message: "account one")
  try await storage.saveOutgoing(draft)
  try await storage.cache?.replaceChannels([cachedChannel()])
  try await storage.cache?.importPosts([cachedPost("one")], channelID: "channel")
  storage.pause(for: one)
  try await storage.reconcile(for: two)
  #expect(try await storage.outgoingMessages().isEmpty)
  #expect(try await storage.cache?.snapshot().channels.isEmpty == true)
  try await storage.clear(for: two)
  try await storage.reconcile(for: one)
  #expect(try await storage.outgoingMessages() == [draft])
  #expect(try await storage.cache?.post(id: "one") != nil)
  try await storage.clear(for: one)
}

@Test func fileCacheProtectsActiveDownloadsAndKeepsExportsOutsideCleanup() async throws {
  let directory = storageDirectory()
  let files = AppOwnedFileCache(directory: directory.appendingPathComponent("Attachments"))
  try await files.put(Data("synthetic".utf8), id: "../../attachment")
  let exported = directory.appendingPathComponent("export.txt")
  try Data("user file".utf8).write(to: exported)
  try await files.protect("../../attachment")
  try await files.evict(retentionDays: 1, now: Date().addingTimeInterval(86_401))
  #expect(try await files.data(id: "../../attachment") != nil)
  await files.unprotect("../../attachment")
  try await files.evict(retentionDays: 1, now: Date().addingTimeInterval(86_401))
  #expect(try await files.data(id: "../../attachment") == nil)
  try await files.close()
  #expect(FileManager.default.fileExists(atPath: exported.path))
  await #expect(throws: PersistenceError.self) { try await files.put(Data(), id: "late") }
}
