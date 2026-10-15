import Foundation
import Network
import Synchronization
import Testing

@testable import MattermacCore

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
  static let requests = Mutex<[URLRequest]>([])

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.requests.withLock { $0.append(request) }
    if request.url!.path == "/pending" { return }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: [
        "Set-Cookie": "MMAUTHTOKEN=syntheticSecret; Path=/; Secure",
        "Cache-Control": "max-age=3600",
      ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
    client?.urlProtocol(self, didLoad: Data("{}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// A real redirect response exercises URLSession's delegate path, which URLProtocol cannot emulate.
private final class LoopbackHTTPFixture: Sendable {
  let listener: NWListener
  let requests = Mutex<[Data]>([])
  private let connections = Mutex<[NWConnection]>([])
  private let queue = DispatchQueue(label: "MattermacCoreTests.HTTPFixture")

  init() throws {
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
          if resumed.withLock({
            let old = $0
            $0 = true
            return !old
          }) {
            continuation.resume()
          }
        case .failed(let error):
          if resumed.withLock({
            let old = $0
            $0 = true
            return !old
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
        receive(connection, accumulated: Data())
      }
      listener.start(queue: queue)
    }
    return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/redirect")!
  }

  private func receive(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, done, error in
      guard let self else {
        connection.cancel()
        return
      }
      let received = accumulated + (data ?? Data())
      if received.range(of: Data("\r\n\r\n".utf8)) != nil {
        requests.withLock { $0.append(received) }
        // A distinct hostname targets this same fixture, so accidental following is observable.
        let location = "http://localhost:\(listener.port!.rawValue)/destination"
        let response =
          "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(
          content: Data(response.utf8),
          completion: .contentProcessed { _ in
            connection.cancel()
          })
      } else if done || error != nil || received.count >= 8192 {
        connection.cancel()
      } else {
        receive(connection, accumulated: received)
      }
    }
  }

  func stop() {
    listener.cancel()
    connections.withLock { connections in
      for connection in connections { connection.cancel() }
      connections.removeAll()
    }
  }
}

@Suite(.serialized)
struct HTTPTransportTests {
  private func transport() -> URLSessionHTTPTransport {
    FixtureURLProtocol.requests.withLock { $0.removeAll() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    return URLSessionHTTPTransport(configuration: configuration)
  }

  @Test func sessionDoesNotReplayCookiesOrCachedResponses() async throws {
    let transport = transport()
    let request = URLRequest(url: URL(string: "https://fixture.invalid/response")!)
    #expect(try await transport.send(request).response.statusCode == 200)
    #expect(try await transport.send(request).data == Data("{}".utf8))
    let requests = FixtureURLProtocol.requests.withLock { $0 }
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
  }

  @Test func redirectsNeverReachAnotherOrigin() async throws {
    let fixture = try LoopbackHTTPFixture()
    defer { fixture.stop() }
    let url = try await fixture.start()
    let transport = URLSessionHTTPTransport()
    var request = URLRequest(url: url, timeoutInterval: 3)
    request.setValue("Bearer syntheticSecret", forHTTPHeaderField: "Authorization")
    let response = try await transport.send(request)
    #expect(response.response.statusCode == 302)
    let requests = fixture.requests.withLock { $0 }
    #expect(requests.count == 1)
  }

  @Test func urlSessionPropagatesCancellation() async throws {
    let transport = transport()
    let request = URLRequest(url: URL(string: "https://fixture.invalid/pending")!)
    let task = Task { try await transport.send(request) }
    for _ in 0..<1000 {
      if FixtureURLProtocol.requests.withLock({ !$0.isEmpty }) { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled URLSession request succeeded")
    } catch {
      #expect((error as? URLError)?.code == .cancelled || error is CancellationError)
    }
    #expect(FixtureURLProtocol.requests.withLock { $0.count } == 1)
  }
}
