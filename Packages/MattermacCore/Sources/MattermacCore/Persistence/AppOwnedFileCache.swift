import CryptoKit
import Foundation

/// App-owned attachment/thumbnail bytes only. User exports never enter this directory.
/// Actor serializes atomic installs, access timestamps, eviction and final logout teardown.
public actor AppOwnedFileCache {
  private let directory: URL
  private var protected: Set<String> = []
  private var closed = false
  init(directory: URL) { self.directory = directory }

  public func protect(_ id: String) throws {
    guard !closed else { throw PersistenceError.closed }
    protected.insert(id)
  }
  public func unprotect(_ id: String) { protected.remove(id) }

  public func put(_ data: Data, id: String) throws {
    guard !closed else { throw PersistenceError.closed }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let url = file(id)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  public func data(id: String, maximumBytes: Int = 32 * 1_024 * 1_024) throws -> Data? {
    guard !closed else { throw PersistenceError.closed }
    let url = file(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= max(0, maximumBytes) else {
      throw PersistenceError.invalidData
    }
    let data = try Data(contentsOf: url)
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    return data
  }

  public func evict(retentionDays: Int, now: Date = Date()) throws {
    guard !closed else { throw PersistenceError.closed }
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    let cutoff = now.addingTimeInterval(-Double(max(1, min(retentionDays, 365))) * 86_400)
    let protectedNames = Set(protected.map { file($0).lastPathComponent })
    for url in try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey])
    {
      if !protectedNames.contains(url.lastPathComponent),
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
          ?? .distantPast < cutoff
      {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  public func close() throws {
    closed = true
    protected = []
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  private func file(_ id: String) -> URL {
    let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(hash)
  }
}
