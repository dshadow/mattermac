import Foundation
import MattermacCore
import Testing

@Test @MainActor func builtApplicationMatchesIdentity() {
  #expect(Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier)
  #expect(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "27.0")
}
