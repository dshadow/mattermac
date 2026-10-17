import AppKit
import Darwin
import MattermacCore
import SwiftUI
import Synchronization
import Testing

@testable import Mattermac

private final class TimelineBenchmarkSocket: WebSocketConnection {
  private let hello = Mutex(false)
  func receive() async throws -> Data {
    let first = hello.withLock { sent in
      defer { sent = true }
      return !sent
    }
    if first { return Data(#"{"event":"hello","seq":0}"#.utf8) }
    try await Task.sleep(for: .seconds(3_600))
    throw CancellationError()
  }
  func send(_ data: Data) async throws {}
  func ping() async throws {}
  func cancel() {}
}

private struct TimelineBenchmarkTransport: WebSocketTransport {
  func connect(_ request: URLRequest) -> any WebSocketConnection { TimelineBenchmarkSocket() }
}

/// Synthetic pages are generated on demand; the fixture never retains a full 10,000-post channel.
private struct TimelineBenchmarkHTTP: HTTPTransport {
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let url = request.url!
    let data: Data
    if url.path.hasSuffix("/users/me") {
      data = Data(#"{"id":"synthetic","username":"synthetic"}"#.utf8)
    } else if url.path.hasSuffix("/teams") {
      data = Data(#"[{"id":"team","name":"team","display_name":"Synthetic"}]"#.utf8)
    } else if url.path.hasSuffix("/channels") {
      data = Data(
        #"[{"id":"timeline","team_id":"team","name":"timeline","display_name":"Synthetic","type":"O"}]"#
          .utf8)
    } else if url.path.hasSuffix("/posts") {
      let before = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "before" }?.value
      let end = before.flatMap { Int($0.dropFirst()) } ?? 10_000
      let size = before == nil ? 200 : 100
      let objects = (max(0, end - size)..<end).map { index in
        MattermostPost(
          id: "p\(index)", userID: "synthetic", channelID: "timeline", rootID: "",
          message:
            "Synthetic \(index) **message** @someone [link](https://example.com) `inline`\n```swift\nlet value = \(index)\n```",
          createAt: Int64(index * 1_000), updateAt: 1, deleteAt: 0, hasReactions: false)
      }
      let posts = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
      data = try JSONSerialization.data(withJSONObject: [
        "order": objects.map(\.id),
        "posts": JSONSerialization.jsonObject(with: JSONEncoder().encode(posts)),
      ])
    } else if url.path.hasSuffix("/users/ids") {
      data = Data(#"[{"id":"synthetic","username":"synthetic"}]"#.utf8)
    } else {
      data = Data("[]".utf8)
    }
    return HTTPResponse(
      data: data,
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private func timelineFootprint() -> UInt64 {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let capacity = Int(count)
  let result = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  return result == KERN_SUCCESS ? info.phys_footprint : 0
}

@MainActor private func timelineWait(_ condition: () -> Bool) async throws {
  for _ in 0..<500 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw WebSocketFailure.timedOut
}

@MainActor private func scrollView(in view: NSView) -> NSScrollView? {
  if let scroll = view as? NSScrollView { return scroll }
  return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
}

/// Opt-in real SwiftUI layout/scroll probe in the hosted app; not a 60 FPS or Instruments claim.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MATTERMAC_TIMELINE_BENCHMARK"] == "1"))
@MainActor func hostedTimelineBenchmark() async throws {
  let session = RealtimeSession(
    transport: TimelineBenchmarkTransport(),
    makeClient: {
      try MattermostAPIClient(server: $0, transport: TimelineBenchmarkHTTP(), log: { _ in })
    })
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let host = NSHostingView(rootView: RealtimeView(realtime: session))
  window.contentView = host
  window.orderFront(nil)
  defer {
    session.stop()
    window.close()
  }
  let credential = SessionCredential(
    server: try MattermostServer("https://example.com"), userID: "synthetic",
    token: try SessionToken("synthetic"))
  let initial = timelineFootprint()
  var footprints: [UInt64] = []
  var timings: [Double] = []
  for _ in 0..<3 {
    session.start(credential: credential, unauthorized: {})
    try await timelineWait { session.state == .connected }
    try await Task.sleep(for: .milliseconds(100))
    let scroll = try #require(scrollView(in: host))
    for _ in 0..<98 {
      let started = ContinuousClock.now
      session.loadOlderMessages()
      try await timelineWait { !session.isLoadingHistory }
      #expect(session.historyMessage == nil)
      #expect(session.synchronization.posts.count <= 400)
      host.layoutSubtreeIfNeeded()
      scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
      scroll.reflectScrolledClipView(scroll.contentView)
      host.layoutSubtreeIfNeeded()
      let duration = started.duration(to: .now).components
      timings.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.synchronization.posts.first?.id == "p0")
    footprints.append(timelineFootprint())
    session.stop()
  }
  let sorted = timings.sorted()
  print(
    "TIMELINE_BENCHMARK posts=10000 cycles=3 page_layout_ms median=\(sorted[sorted.count / 2]) worst=\(sorted.last ?? 0)"
  )
  print("TIMELINE_BENCHMARK footprint_bytes initial=\(initial) cycles=\(footprints)")
}
