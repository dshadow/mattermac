import Foundation

public struct APIRetryPolicy: Sendable {
  public let maximumAttempts: Int
  public let maximumDelay: TimeInterval

  public static let standard = APIRetryPolicy(attempts: 3, delay: 30)

  public init(maximumAttempts: Int, maximumDelay: TimeInterval = 30) throws {
    guard (1...5).contains(maximumAttempts), maximumDelay.isFinite,
      (0...60).contains(maximumDelay)
    else { throw APIError.invalidConfiguration }
    self.init(attempts: maximumAttempts, delay: maximumDelay)
  }

  private init(attempts: Int, delay: TimeInterval) {
    maximumAttempts = attempts
    maximumDelay = delay
  }

  func delay(attempt: Int, serverMinimum: TimeInterval?) -> TimeInterval? {
    let backoff = min(pow(2, Double(attempt - 1)) * 0.5, maximumDelay)
    let delay = max(backoff, serverMinimum ?? 0)
    // Do not shorten long server guidance to our local retry budget.
    return delay <= maximumDelay ? delay : nil
  }

  static func serverDelay(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
    if let header = response.value(forHTTPHeaderField: "Retry-After") {
      let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
      if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
      if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
    }
    if response.statusCode == 429,
      let header = response.value(forHTTPHeaderField: "X-Ratelimit-Reset"),
      let reset = TimeInterval(header), reset.isFinite, reset >= 0
    {
      // Mattermost 11.7.11 emits ceil(ResetAfter.Seconds()), not a Unix timestamp.
      return reset
    }
    return nil
  }
}
