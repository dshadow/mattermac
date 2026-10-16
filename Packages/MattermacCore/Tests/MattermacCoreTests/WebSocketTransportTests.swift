import CryptoKit
import Foundation
import Network
import Synchronization
import Testing

@testable import MattermacCore

/// Real loopback HTTP upgrade and RFC 6455 frames; no credentials or external services.
private final class LoopbackWebSocket: Sendable {
  let listener: NWListener
  let requests = Mutex<[String]>([])
  let messages = Mutex<[Data]>([])
  let frameHeaders = Mutex<[String]>([])
  private let connections = Mutex<[NWConnection]>([])
  private let queue = DispatchQueue(label: "MattermacCoreTests.WebSocketFixture")
  private let redirect: Bool

  init(redirect: Bool = false) throws {
    self.redirect = redirect
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> URL {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      let resumed = Mutex(false)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if !resumed.withLock({ value in
            let old = value
            value = true
            return old
          }) {
            continuation.resume()
          }
        case .failed(let error):
          if !resumed.withLock({ value in
            let old = value
            value = true
            return old
          }) {
            continuation.resume(throwing: error)
          }
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else {
          connection.cancel()
          return
        }
        connections.withLock { $0.append(connection) }
        connection.start(queue: queue)
        readUpgrade(connection, accumulated: Data())
      }
      listener.start(queue: queue)
    }
    return URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)/api/v4/websocket")!
  }

  private func readUpgrade(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, done, error in
      guard let self else {
        connection.cancel()
        return
      }
      let bytes = accumulated + (data ?? Data())
      guard bytes.count < 8192, !done, error == nil else {
        connection.cancel()
        return
      }
      guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
        readUpgrade(connection, accumulated: bytes)
        return
      }
      let request = String(decoding: bytes, as: UTF8.self)
      requests.withLock { $0.append(request) }
      if redirect {
        let location = "ws://localhost:\(listener.port!.rawValue)/elsewhere"
        let response =
          "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(
          content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        return
      }
      guard
        let key = request.components(separatedBy: "\r\n").first(where: {
          $0.lowercased().hasPrefix("sec-websocket-key:")
        })?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
      else {
        connection.cancel()
        return
      }
      let digest = Insecure.SHA1.hash(
        data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
      let accept = Data(digest).base64EncodedString()
      let response =
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
      let hello = Data(#"{"event":"hello","seq":0,"data":{}}"#.utf8)
      connection.send(
        content: Data(response.utf8) + frame(hello), completion: .contentProcessed { _ in })
      readFrames(connection, accumulated: Data())
    }
  }

  private func frame(_ bytes: Data, opcode: UInt8 = 1) -> Data {
    precondition(bytes.count < 126)
    return Data([0x80 | opcode, UInt8(bytes.count)]) + bytes
  }

  private func readFrames(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, done, error in
      guard let self else {
        connection.cancel()
        return
      }
      var bytes = Array(accumulated + (data ?? Data()))
      frameHeaders.withLock { $0.append(bytes.prefix(2).map(String.init).joined(separator: ",")) }
      guard bytes.count < 8192, !done, error == nil else {
        connection.cancel()
        return
      }
      while bytes.count >= 6 {
        let opcode = bytes[0] & 0x0f
        let length = Int(bytes[1] & 0x7f)
        guard length < 126, bytes[1] & 0x80 != 0 else {
          connection.cancel()
          return
        }
        guard bytes.count >= 6 + length else { break }
        let mask = Array(bytes[2..<6])
        let payload = Data((0..<length).map { bytes[6 + $0] ^ mask[$0 % 4] })
        bytes.removeFirst(6 + length)
        if opcode == 1 {
          messages.withLock { $0.append(payload) }
        } else if opcode == 9 {
          connection.send(
            content: frame(payload, opcode: 10), completion: .contentProcessed { _ in })
        } else if opcode == 8 {
          connection.cancel()
          return
        }
      }
      readFrames(connection, accumulated: Data(bytes))
    }
  }

  func stop() {
    listener.cancel()
    connections.withLock { values in
      for connection in values { connection.cancel() }
      values = []
    }
  }
}

@Suite struct WebSocketTransportTests {
  @Test func nativeUpgradeFramesPingAndCancellation() async throws {
    let fixture = try LoopbackWebSocket()
    defer { fixture.stop() }
    var request = URLRequest(url: try await fixture.start())
    request.setValue("Bearer syntheticSecret", forHTTPHeaderField: "Authorization")
    let connection = URLSessionWebSocketTransport().connect(request)
    defer { connection.cancel() }
    let hello: Data
    do {
      hello = try await withSocketDeadline(connection, seconds: 3) {
        try await connection.receive()
      }
    } catch {
      Issue.record("Upgrade/hello failed; requests=\(fixture.requests.withLock { $0.count })")
      throw error
    }
    #expect(try WebSocketEvent.decode(hello).event == "hello")
    #expect(fixture.requests.withLock { $0.first?.contains("Bearer syntheticSecret") } == true)
    try await connection.send(Data(#"{"action":"fixture"}"#.utf8))
    // Keep the reader active, as in RealtimeSession, so URLSession processes control frames.
    let pending = Task {
      try await withSocketDeadline(connection, seconds: 6) { try await connection.receive() }
    }
    do {
      try await withSocketDeadline(connection, seconds: 3) { try await connection.ping() }
    } catch {
      Issue.record("Ping failed; frame headers=\(fixture.frameHeaders.withLock { $0 })")
      throw error
    }
    #expect(fixture.messages.withLock { $0 } == [Data(#"{"action":"fixture"}"#.utf8)])
    pending.cancel()
    await #expect(throws: (any Error).self) { try await pending.value }
  }

  @Test func nativeSocketRejectsRedirects() async throws {
    let fixture = try LoopbackWebSocket(redirect: true)
    defer { fixture.stop() }
    var request = URLRequest(url: try await fixture.start())
    request.setValue("Bearer syntheticSecret", forHTTPHeaderField: "Authorization")
    let connection = URLSessionWebSocketTransport().connect(request)
    defer { connection.cancel() }
    await #expect(throws: (any Error).self) {
      try await withSocketDeadline(connection, seconds: 3) { try await connection.receive() }
    }
    #expect(fixture.requests.withLock { $0.count } == 1)
  }
}
