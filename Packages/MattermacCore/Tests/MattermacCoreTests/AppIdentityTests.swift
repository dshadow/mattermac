import Testing

@testable import MattermacCore

@Test func identityRemainsStable() {
  #expect(AppIdentity.bundleIdentifier == "io.github.dshadow.mattermac")
}
