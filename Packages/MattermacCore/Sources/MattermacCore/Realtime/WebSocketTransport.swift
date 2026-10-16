import Foundation

public enum WebSocketFailure: Error, Equatable, Sendable {
  case disconnected, malformedMessage, sequenceGap, timedOut, capacityExceeded
}

/// One reader per connection. Cancellation must unblock receive and ping.
public protocol WebSocketConnection: Sendable {
  func receive() async throws -> Data
  func send(_ data: Data) async throws
  func ping() async throws
  func cancel()
}

public protocol WebSocketTransport: Sendable {
  func connect(_ request: URLRequest) -> any WebSocketConnection
}

public struct URLSessionWebSocketTransport: WebSocketTransport {
  public init() {}
  public func connect(_ request: URLRequest) -> any WebSocketConnection {
    NativeWebSocket(request: request)
  }
}

private final class NativeWebSocket: WebSocketConnection {
  private let session: URLSession
  private let task: URLSessionWebSocketTask

  init(request: URLRequest) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.waitsForConnectivity = false
    session = URLSession(
      configuration: configuration, delegate: WebSocketRedirectGuard(), delegateQueue: nil)
    task = session.webSocketTask(with: request)
    task.maximumMessageSize = 1_048_576
    task.resume()
  }

  deinit { cancel() }

  func receive() async throws -> Data {
    do {
      switch try await task.receive() {
      case .string(let value): return Data(value.utf8)
      case .data(let value): return value
      @unknown default: throw WebSocketFailure.malformedMessage
      }
    } catch {
      if (task.response as? HTTPURLResponse)?.statusCode == 401 { throw APIError.unauthorized }
      throw WebSocketFailure.disconnected
    }
  }

  func send(_ data: Data) async throws {
    guard let string = String(data: data, encoding: .utf8) else {
      throw WebSocketFailure.malformedMessage
    }
    try await task.send(.string(string))
  }

  func ping() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      task.sendPing { error in
        if error != nil {
          continuation.resume(throwing: WebSocketFailure.disconnected)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func cancel() {
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
}

private final class WebSocketRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

extension MattermostServer {
  public func webSocketURL() throws -> URL {
    var components = URLComponents(
      url: try url(path: ["websocket"]), resolvingAgainstBaseURL: false)!
    components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
    guard let url = components.url else { throw APIError.invalidServerURL }
    return url
  }
}

/// The deadline closes the socket before draining children, including a suspended receive.
func withSocketDeadline<Value: Sendable>(
  _ socket: any WebSocketConnection, seconds: TimeInterval,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withTaskCancellationHandler {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        socket.cancel()
        throw WebSocketFailure.timedOut
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  } onCancel: {
    socket.cancel()
  }
}
