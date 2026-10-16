import Foundation
import MattermacCore
import Testing

@Test @MainActor func builtApplicationMatchesIdentity() {
  #expect(Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier)
  #expect(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "27.0")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MATTERMAC_LOCAL_INTEGRATION"] == "1"))
@MainActor func hostedAppCanReachLocalComposeServer() async throws {
  let url = try #require(URL(string: "http://127.0.0.1:8065/api/v4/system/ping"))
  var request = URLRequest(url: url)
  request.timeoutInterval = 5
  let (data, response) = try await URLSession.shared.data(for: request)
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  let payload = try JSONDecoder().decode(LocalPing.self, from: data)
  #expect(payload.status == "OK")
}

private struct LocalPing: Decodable { let status: String }
