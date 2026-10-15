import Foundation

public struct HTTPResponse: Sendable {
  public let data: Data
  public let response: HTTPURLResponse

  public init(data: Data, response: HTTPURLResponse) {
    self.data = data
    self.response = response
  }
}

/// Implementations must preserve task cancellation and must not follow redirects.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> HTTPResponse
}

public final class URLSessionHTTPTransport: HTTPTransport {
  private let session: URLSession

  public convenience init() {
    self.init(configuration: .ephemeral)
  }

  // Test injection still receives the same privacy and redirect restrictions.
  init(configuration: URLSessionConfiguration) {
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForResource = 60
    session = URLSession(
      configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
    return HTTPResponse(data: data, response: response)
  }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
