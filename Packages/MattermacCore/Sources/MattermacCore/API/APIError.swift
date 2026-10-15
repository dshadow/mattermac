import Foundation

/// Deliberately excludes server messages, response bodies, URLs, and underlying errors.
public enum APIError: Error, Sendable, Equatable {
  case invalidServerURL
  case invalidIdentifier
  case invalidPagination
  case invalidConfiguration
  case invalidCredentials
  case missingSessionToken
  case invalidResponse
  case encodingFailed
  case decodingFailed
  case unauthorized
  case forbidden
  case rateLimited(retryAfter: TimeInterval?)
  case http(status: Int, retryAfter: TimeInterval?)
  case timedOut
  case offline
  case network(code: Int)
  case transportFailed
}
