import Foundation
import Observation

/// App-wide account lifecycle. A paused or cleared account cannot accept new writes.
@MainActor @Observable public final class AccountPersistence: AccountSessionData {
  public private(set) var cache: CacheRepository?
  public private(set) var files: AppOwnedFileCache?
  public private(set) var notice: String?
  public private(set) var usage: StoreUsage?
  public private(set) var retentionDays: Int
  private let root: URL
  private let preferences: UserDefaults
  private var account: SessionAccount?
  private var outgoing: OutgoingRepository?
  private var unsent = true
  private var paused = true
  private var generation = UUID()

  public init(root: URL? = nil, preferences: UserDefaults = .standard) {
    self.root =
      root
      ?? URL.applicationSupportDirectory.appendingPathComponent(
        "Mattermac/Accounts", isDirectory: true)
    self.preferences = preferences
    let days = preferences.integer(forKey: "cacheRetentionDays")
    retentionDays = days > 0 ? min(days, 365) : 30
  }

  public func hasUnsentContent(for account: SessionAccount) -> Bool {
    self.account == account ? unsent : true
  }

  public func pause(for account: SessionAccount) {
    guard self.account == account else { return }
    paused = true
    generation = UUID()
  }

  public func reconcile(for account: SessionAccount) async throws {
    generation = UUID()
    let current = generation
    paused = true
    unsent = true
    if self.account != account || cache == nil || outgoing == nil {
      try await cache?.persistence.close()
      try await outgoing?.persistence.close()
      cache = nil
      outgoing = nil
      self.account = account
      let directory = PersistenceController.accountDirectory(root: root, account: account)
      files = AppOwnedFileCache(directory: directory.appendingPathComponent("Attachments"))
      let durable = PersistenceController(
        directory: directory.appendingPathComponent("Outgoing"), durable: true)
      // Never rebuild this store. Migration/write errors preserve the original files and block login.
      try await durable.open()
      outgoing = OutgoingRepository(durable)
      let disposable = PersistenceController(directory: directory.appendingPathComponent("Cache"))
      do {
        try await disposable.open()
        cache = CacheRepository(disposable)
      } catch {
        try await disposable.close(removeFiles: true)
        let rebuilt = PersistenceController(directory: directory.appendingPathComponent("Cache"))
        try await rebuilt.open()
        cache = CacheRepository(rebuilt)
        notice = "Local message cache was rebuilt. Drafts and pending messages were preserved."
      }
    }
    guard current == generation else { throw AuthenticationError.staleSession }
    unsent = try await outgoing?.hasUnsentContent() ?? true
    // No writes are replayed here. Phase 8 will resolve submitting/uncertain server outcomes.
    try await cache?.evict(retentionDays: retentionDays)
    guard current == generation else { throw AuthenticationError.staleSession }
    paused = false
  }

  public func saveOutgoing(_ message: OutgoingMessage) async throws {
    guard !paused, let outgoing else { throw PersistenceError.closed }
    // Conservative while saving: logout must never skip confirmation during an in-flight write.
    unsent = true
    try await outgoing.save(message)
  }

  public func outgoingMessages() async throws -> [OutgoingMessage] {
    guard !paused, let outgoing else { throw PersistenceError.closed }
    return try await outgoing.messages()
  }

  public func clear(for account: SessionAccount) async throws {
    pause(for: account)
    if self.account == account {
      try await files?.close()
      try await cache?.persistence.close(removeFiles: true)
      try await outgoing?.persistence.close(removeFiles: true)
      cache = nil
      files = nil
      outgoing = nil
      self.account = nil
      unsent = false
    }
    let directory = PersistenceController.accountDirectory(root: root, account: account)
    try await Task.detached {
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
    }.value
    usage = nil
    notice = nil
  }

  /// Only disposable cache is rebuilt. The outgoing store is neither copied nor modified.
  public func rebuildCache() async throws {
    guard !paused, let account else { throw PersistenceError.closed }
    let current = generation
    try await cache?.persistence.close(removeFiles: true)
    let directory = PersistenceController.accountDirectory(root: root, account: account)
    let rebuilt = PersistenceController(directory: directory.appendingPathComponent("Cache"))
    try await rebuilt.open()
    guard current == generation, !paused else {
      try await rebuilt.close()
      throw AuthenticationError.staleSession
    }
    cache = CacheRepository(rebuilt)
    notice = "Local message cache was rebuilt. Drafts and pending messages were preserved."
  }

  public func updateRetention(days: Int, activeChannelID: String?) async {
    retentionDays = max(1, min(days, 365))
    preferences.set(retentionDays, forKey: "cacheRetentionDays")
    await maintain(activeChannelID: activeChannelID)
  }

  public func invalidatePermissions() async throws {
    guard !paused, let account else { throw PersistenceError.closed }
    try await cache?.invalidateMemberships()
    try await files?.close()
    let directory = PersistenceController.accountDirectory(root: root, account: account)
    files = AppOwnedFileCache(directory: directory.appendingPathComponent("Attachments"))
  }

  public func maintain(activeChannelID: String?) async {
    guard !paused, let cache else { return }
    do {
      try await cache.evict(retentionDays: retentionDays, activeChannelID: activeChannelID)
      try await files?.evict(retentionDays: retentionDays)
      usage = try await cache.persistence.usage()
    } catch {
      notice = "Local cache maintenance failed. Your drafts are preserved."
    }
  }
}
