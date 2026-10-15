import Foundation

public struct MattermostServer: Sendable {
  public let baseURL: URL

  /// Plain HTTP is available only for an explicitly opted-in loopback development server.
  public init(_ address: String, allowInsecureLocalhost: Bool = false) throws {
    guard let components = URLComponents(string: address),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(), !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.port.map({ (1...65_535).contains($0) }) ?? true,
      scheme == "https"
        || (scheme == "http" && allowInsecureLocalhost
          && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
      !components.path.contains("\\"),
      !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      let url = components.url
    else { throw APIError.invalidServerURL }
    baseURL = url
  }

  func url(path: [String], query: [URLQueryItem] = []) throws -> URL {
    guard path.allSatisfy(Self.isIdentifier) else { throw APIError.invalidIdentifier }
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw APIError.invalidServerURL
    }
    var prefix = components.percentEncodedPath
    while prefix.hasSuffix("/") { prefix.removeLast() }
    components.percentEncodedPath = prefix + "/api/v4/" + path.joined(separator: "/")
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw APIError.invalidServerURL }
    return url
  }

  private static func isIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
      }
  }
}

public struct PostPage: Sendable {
  public let number: Int
  public let size: Int

  public init(number: Int = 0, size: Int = 60) throws {
    guard number >= 0, (1...200).contains(size) else { throw APIError.invalidPagination }
    self.number = number
    self.size = size
  }

  public static let recent = PostPage()

  private init() {
    number = 0
    size = 60
  }

  var query: [URLQueryItem] {
    [
      URLQueryItem(name: "page", value: String(number)),
      URLQueryItem(name: "per_page", value: String(size)),
    ]
  }
}
