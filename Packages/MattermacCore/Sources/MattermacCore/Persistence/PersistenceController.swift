import CoreData
import CryptoKit
import Foundation

public enum PersistenceError: Error { case unavailable, closed, invalidData, unsupportedVersion }

public struct StoreUsage: Sendable {
  public let records: Int
  public let fileBytes: Int64
  public let physicalBytes: Int64
}

/// All container, context and filesystem access is confined to queue, including load and teardown.
/// No managed object escapes a transaction. The viewContext is never used.
public final class PersistenceController: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.github.dshadow.mattermac.persistence")
  private let directory: URL
  private let durable: Bool
  private let version: Int
  private var container: NSPersistentContainer?
  private var closed = false
  private var sequence: Int64 = 0

  public static func accountDirectory(root: URL, account: SessionAccount) -> URL {
    let identity = Data((account.serverAddress + "\u{0}" + account.userID).utf8)
    let name = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    return root.appendingPathComponent(name, isDirectory: true)
  }

  init(directory: URL, durable: Bool = false, version: Int = 2) {
    self.directory = directory
    self.durable = durable
    self.version = version
  }

  func open() async throws {
    try await schedule {
      guard !self.closed else { throw PersistenceError.closed }
      if self.container != nil { return }
      try FileManager.default.createDirectory(
        at: self.directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
      let container = NSPersistentContainer(
        name: self.durable ? "Outgoing" : "Cache",
        managedObjectModel: PersistenceModel.make(version: self.version, durable: self.durable))
      let description = NSPersistentStoreDescription(
        url: self.directory.appendingPathComponent("store.sqlite"))
      description.shouldAddStoreAsynchronously = false
      description.shouldMigrateStoreAutomatically = true
      description.shouldInferMappingModelAutomatically = true
      container.persistentStoreDescriptions = [description]
      if let url = description.url, FileManager.default.fileExists(atPath: url.path) {
        let metadata: [String: Any]
        do {
          metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: url)
        } catch { throw PersistenceError.unavailable }
        let identifiers = metadata[NSStoreModelVersionIdentifiersKey] as? [String] ?? []
        let known = Set(
          (1...self.version).map {
            "Mattermac-\(self.durable ? "Outgoing" : "Cache")-\($0)"
          })
        guard !identifiers.isEmpty, Set(identifiers).isSubset(of: known) else {
          throw PersistenceError.unsupportedVersion
        }
      }
      var failure: (any Error)?
      container.loadPersistentStores { _, error in failure = error }
      if failure != nil { throw PersistenceError.unavailable }
      self.container = container
      let context = container.newBackgroundContext()
      self.sequence = try context.performAndWait {
        try Records.fetch(
          context, predicate: NSPredicate(value: true), limit: 1,
          sort: [NSSortDescriptor(key: "sequence", ascending: false)]
        ).first?.value(forKey: "sequence") as? Int64 ?? 0
      }
      for file in try FileManager.default.contentsOfDirectory(
        at: self.directory, includingPropertiesForKeys: nil)
      {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
    }
  }

  /// Synchronization closures use one atomic save, including checkpoint. Maintenance batch deletes
  /// commit independently and are idempotent; callers must not mix them with synchronization writes.
  func transaction<T: Sendable>(
    _ operation: @escaping @Sendable (NSManagedObjectContext, Int64) throws -> T
  ) async throws -> T {
    try await schedule {
      guard !self.closed, let container = self.container else { throw PersistenceError.closed }
      let context = container.newBackgroundContext()
      context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
      context.undoManager = nil
      self.sequence += 1
      let sequence = self.sequence
      return try context.performAndWait {
        defer { context.reset() }
        do {
          let result = try operation(context, sequence)
          if context.hasChanges { try context.save() }
          return result
        } catch {
          context.rollback()
          throw PersistenceError.unavailable
        }
      }
    }
  }

  public func usage() async throws -> StoreUsage {
    let count = try await transaction { context, _ in
      try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Record"))
    }
    return try await schedule {
      var bytes: Int64 = 0
      var allocated: Int64 = 0
      for file in try FileManager.default.contentsOfDirectory(
        at: self.directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
      {
        bytes +=
          (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
          .int64Value ?? 0
        allocated += Int64(
          try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        )
      }
      return StoreUsage(records: count, fileBytes: bytes, physicalBytes: allocated)
    }
  }

  /// Permanently fences this handle. Old queued callers cannot recreate a cleared store.
  public func close(removeFiles: Bool = false) async throws {
    try await schedule {
      self.closed = true
      if let container = self.container {
        for store in container.persistentStoreCoordinator.persistentStores {
          try container.persistentStoreCoordinator.remove(store)
        }
        self.container = nil
      }
      if removeFiles, FileManager.default.fileExists(atPath: self.directory.path) {
        try FileManager.default.removeItem(at: self.directory)
      }
    }
  }

  private func schedule<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try work() }) }
    }
  }
}

// Context-local helpers. All requests have explicit bounds; pagination never uses offsets.
enum Records {
  static func fetch(
    _ context: NSManagedObjectContext, predicate: NSPredicate, limit: Int = 200,
    sort: [NSSortDescriptor] = []
  ) throws -> [NSManagedObject] {
    let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
    request.predicate = predicate
    request.fetchLimit = max(1, min(limit, 10_000))
    request.fetchBatchSize = min(request.fetchLimit, 200)
    request.sortDescriptors = sort
    return try context.fetch(request)
  }

  static func find(_ context: NSManagedObjectContext, _ kind: String, _ id: String) throws
    -> NSManagedObject?
  {
    try fetch(
      context, predicate: NSPredicate(format: "kind == %@ AND id == %@", kind, id), limit: 1
    ).first
  }

  static func put<T: Encodable>(
    _ context: NSManagedObjectContext, kind: String, id: String, value: T,
    channel: String = "", root: String = "", sortAt: Int64 = 0,
    revision: Int64 = 0, deleted: Bool = false, sequence: Int64 = 0, now: Date
  ) throws {
    let object =
      try find(context, kind, id)
      ?? NSEntityDescription.insertNewObject(forEntityName: "Record", into: context)
    object.setValue(kind, forKey: "kind")
    object.setValue(id, forKey: "id")
    object.setValue(channel, forKey: "channelID")
    object.setValue(root, forKey: "rootID")
    object.setValue(sortAt, forKey: "sortAt")
    object.setValue(revision, forKey: "revision")
    object.setValue(deleted, forKey: "isTombstone")
    object.setValue(try JSONEncoder().encode(value), forKey: "payload")
    object.setValue(now, forKey: "accessedAt")
    object.setValue(sequence, forKey: "sequence")
    if object.entity.attributesByName["createdAt"] != nil, object.value(forKey: "createdAt") == nil
    {
      object.setValue(now, forKey: "createdAt")
    }
  }

  static func decode<T: Decodable>(_ object: NSManagedObject, as: T.Type = T.self) throws -> T {
    guard let data = object.value(forKey: "payload") as? Data else {
      throw PersistenceError.invalidData
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  static func delete(_ context: NSManagedObjectContext, predicate: NSPredicate) throws {
    while true {
      let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Record")
      request.predicate = predicate
      request.fetchLimit = 200
      let deletion = NSBatchDeleteRequest(fetchRequest: request)
      deletion.resultType = .resultTypeObjectIDs
      let result = try context.execute(deletion) as? NSBatchDeleteResult
      let ids = result?.result as? [NSManagedObjectID] ?? []
      if ids.isEmpty { break }
      NSManagedObjectContext.mergeChanges(
        fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [context])
    }
  }
}
