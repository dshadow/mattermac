import Darwin
import Foundation
import Testing

@testable import MattermacCore

private func footprintBytes() throws -> UInt64 {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let capacity = Int(count)
  let result = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  guard result == KERN_SUCCESS else { throw PersistenceError.unavailable }
  return info.phys_footprint
}

/// Opt-in fixture benchmark, separate from app/Release performance acceptance.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MATTERMAC_PERSISTENCE_BENCHMARK"] == "1"))
func boundedPersistenceBenchmark() async throws {
  var directory = URL(fileURLWithPath: #filePath)
  for _ in 0..<5 { directory.deleteLastPathComponent() }
  directory.appendPathComponent("tmp/persistence-benchmark/\(UUID().uuidString)")
  let controller = PersistenceController(directory: directory)
  try await controller.open()
  let repository = CacheRepository(controller)
  let channels = (0..<5).map {
    MattermostChannel(
      id: "channel\($0)", teamID: "team", name: "test\($0)", displayName: "Test", type: "O")
  }
  try await repository.replaceChannels(channels)
  let initialFootprint = try footprintBytes()
  let initialUsage = try await controller.usage()
  let start = ContinuousClock.now
  for channel in channels {
    for batch in 0..<10 {
      let posts = (0..<200).map { index in
        MattermostPost(
          id: "\(channel.id)-\(batch * 200 + index)", userID: "synthetic",
          channelID: channel.id, rootID: "", message: String(repeating: "synthetic ", count: 100),
          createAt: Int64(batch * 200 + index), updateAt: 1, deleteAt: 0, hasReactions: false)
      }
      try await repository.importPosts(posts, channelID: channel.id)
    }
  }
  let importDuration = start.duration(to: .now)
  let importedFootprint = try footprintBytes()
  let importedUsage = try await controller.usage()
  var timings: [Double] = []
  var footprints: [UInt64] = []
  for iteration in 0..<100 {
    let began = ContinuousClock.now
    try await repository.selectChannel(channels[iteration % 5].id)
    let snapshot = try await repository.snapshot()
    #expect(snapshot.posts.count == 200)
    let duration = began.duration(to: .now).components
    timings.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
    if iteration % 20 == 19 { footprints.append(try footprintBytes()) }
  }
  try await repository.evict(retentionDays: 30, now: Date().addingTimeInterval(31 * 86_400))
  let evictedUsage = try await controller.usage()
  let evictedFootprint = try footprintBytes()
  #expect(try await repository.posts(channelID: channels[0].id).posts.isEmpty)
  let sorted = timings.sorted()
  print("PERSISTENCE_BENCHMARK posts=10000 channels=5 imports=\(importDuration)")
  print("PERSISTENCE_BENCHMARK switch_ms median=\(sorted[50]) worst=\(sorted.last ?? 0)")
  print(
    "PERSISTENCE_BENCHMARK footprint_bytes initial=\(initialFootprint) imported=\(importedFootprint) switches=\(footprints) evicted=\(evictedFootprint)"
  )
  print(
    "PERSISTENCE_BENCHMARK records initial=\(initialUsage.records) imported=\(importedUsage.records) evicted=\(evictedUsage.records)"
  )
  print(
    "PERSISTENCE_BENCHMARK file_bytes initial=\(initialUsage.fileBytes) imported=\(importedUsage.fileBytes) evicted=\(evictedUsage.fileBytes)"
  )
  print(
    "PERSISTENCE_BENCHMARK allocated_bytes initial=\(initialUsage.physicalBytes) imported=\(importedUsage.physicalBytes) evicted=\(evictedUsage.physicalBytes)"
  )
  try await controller.close(removeFiles: true)
}
