import Foundation
import Testing

@testable import MattermacCore

@Test(arguments: [
  "https://example.com", "https://example.com/", "https://example.com:8443/chat/",
  "https://example.com/my%20chat/",
])
func endpointConstructionPreservesDeploymentPath(address: String) throws {
  let server = try MattermostServer(address)
  let url = try server.url(path: ["users", "me"])
  #expect(url.host == server.baseURL.host)
  #expect(url.port == server.baseURL.port)
  #expect(url.path.hasSuffix("/api/v4/users/me"))
  if address.contains("chat") { #expect(url.path.contains("chat/api/v4")) }
  if address.contains("%20") { #expect(url.absoluteString.contains("my%20chat/api/v4")) }
}

@Test(arguments: [
  "http://example.com", "http://localhost:8065", "ftp://example.com",
  "https://user:password@example.com", "https://example.com?token=secret",
  "https://example.com/#fragment", "https://example.com/../outside",
  "https://example.com/%2e%2e/outside", "https://example.com/a%5cb", "/relative", "",
  "https://example.com:99999",
])
func invalidServersAreRejected(address: String) {
  #expect(throws: APIError.invalidServerURL) { try MattermostServer(address) }
}

@Test(arguments: ["http://localhost:8065", "http://127.0.0.1:8065", "http://[::1]:8065"])
func insecureDevelopmentRequiresExplicitLoopbackOptIn(address: String) throws {
  _ = try MattermostServer(address, allowInsecureLocalhost: true)
  #expect(throws: APIError.invalidServerURL) {
    try MattermostServer("http://example.com", allowInsecureLocalhost: true)
  }
  #expect(throws: APIError.invalidServerURL) {
    try MattermostServer("http://localhost.example.com", allowInsecureLocalhost: true)
  }
}

@Test(arguments: [
  "", "..", "../users", "id?query", "id#fragment", "a%2fb", "a/b", "a\\b", "a b", "ü",
])
func pathInjectionIsRejected(identifier: String) throws {
  let server = try MattermostServer("https://example.com/subpath")
  #expect(throws: APIError.invalidIdentifier) {
    try server.url(path: ["channels", identifier, "posts"])
  }
}

@Test func paginationAndConfigurationAreBounded() throws {
  #expect(PostPage.recent.number == 0)
  #expect(PostPage.recent.size == 60)
  #expect(throws: APIError.invalidPagination) { try PostPage(number: -1) }
  #expect(throws: APIError.invalidPagination) { try PostPage(size: 0) }
  #expect(throws: APIError.invalidPagination) { try PostPage(size: 201) }
  #expect(throws: APIError.invalidConfiguration) { try APIRetryPolicy(maximumAttempts: 0) }
  #expect(throws: APIError.invalidConfiguration) { try APIRetryPolicy(maximumAttempts: 6) }
  #expect(throws: APIError.invalidConfiguration) {
    try APIRetryPolicy(maximumAttempts: 1, maximumDelay: .infinity)
  }
  for timeout: TimeInterval in [0, -1, .infinity, .nan, 61] {
    #expect(throws: APIError.invalidConfiguration) {
      try MattermostAPIClient(
        server: MattermostServer("https://example.com"), requestTimeout: timeout)
    }
  }
  #expect(throws: APIError.invalidCredentials) { try SessionToken("bad\r\nheader") }
  #expect(throws: APIError.invalidCredentials) { try SessionToken("") }
  #expect(throws: APIError.invalidCredentials) { try LoginCredentials(loginID: "", password: "p") }
}

@Test func retryGuidanceParsesSecondsDatesAndRelativeReset() throws {
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  func response(_ headers: [String: String]) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://example.com")!, statusCode: 429,
      httpVersion: "HTTP/1.1", headerFields: headers)!
  }
  #expect(APIRetryPolicy.serverDelay(response(["Retry-After": "4"]), now: now) == 4)
  #expect(
    APIRetryPolicy.serverDelay(response(["Retry-After": "Tue, 14 Nov 2023 22:13:25 GMT"]), now: now)
      == 5)
  #expect(
    APIRetryPolicy.serverDelay(response(["Retry-After": "Tue, 14 Nov 2023 22:13:15 GMT"]), now: now)
      == 0)
  #expect(APIRetryPolicy.serverDelay(response(["X-Ratelimit-Reset": "7"]), now: now) == 7)
  #expect(
    APIRetryPolicy.serverDelay(response(["Retry-After": "2", "X-Ratelimit-Reset": "7"]), now: now)
      == 2)
  for value in ["invalid", "-1", "nan", "inf"] {
    #expect(APIRetryPolicy.serverDelay(response(["Retry-After": value]), now: now) == nil)
  }
  #expect(APIRetryPolicy.standard.delay(attempt: 1, serverMinimum: 120) == nil)
}
