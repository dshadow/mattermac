import CryptoKit
import Foundation
import Testing

@testable import MattermacCore

@MainActor private final class LocalServerCredentialStore: SessionCredentialStore {
  var credential: SessionCredential?
  func load() throws -> SessionCredential? { credential }
  func save(_ credential: SessionCredential) throws { self.credential = credential }
  func delete() throws { credential = nil }
}

private enum LocalServerTestError: Error {
  case missingCredentials, invalidSecret, acceptanceFailed
}

/// Opt-in acceptance against the repository's Compose server. No credentials go into test output.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MATTERMAC_LOCAL_INTEGRATION"] == "1"))
@MainActor func localComposeAuthenticationAndRealtime() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard let login = environment["MATTERMOST_TEST_USERNAME"] ?? environment["MATTERMOST_TEST_EMAIL"],
    let password = environment["MATTERMOST_TEST_PASSWORD"], !login.isEmpty, !password.isEmpty
  else { throw LocalServerTestError.missingCredentials }
  let code: String
  if let secret = environment["MATTERMOST_TEST_TOTP_SECRET"], !secret.isEmpty {
    code = try localTestCode(secret)
  } else {
    code = environment["MATTERMOST_TEST_MFA_CODE"] ?? ""
  }
  let store = LocalServerCredentialStore()
  let realtime = RealtimeSession(allowInsecureLocalhost: true)
  let session = AuthenticationSession(
    store: store, realtime: realtime, allowInsecureLocalhost: true)
  await session.start()
  await session.login(
    address: "http://127.0.0.1:8065", loginID: login, password: password, mfaCode: code)
  do {
    guard session.phase == .authenticated else { throw LocalServerTestError.acceptanceFailed }
    try await waitForLocalConnection(realtime)
    guard !realtime.synchronization.channels.isEmpty else {
      throw LocalServerTestError.acceptanceFailed
    }
    // A channel change restarts the socket and loads the selected channel's REST snapshot.
    if let channel = realtime.synchronization.channels.first {
      realtime.selectChannel(channel.id)
      try await waitForLocalConnection(realtime)
    }
    realtime.suspend()
    #expect(realtime.state == .suspended)
    realtime.resume()
    try await waitForLocalConnection(realtime)
    await session.verify()
    guard session.phase == .authenticated, session.message == nil else {
      throw LocalServerTestError.acceptanceFailed
    }
    realtime.stop()
    let restored = AuthenticationSession(store: store, allowInsecureLocalhost: true)
    await restored.start()
    guard restored.phase == .authenticated else { throw LocalServerTestError.acceptanceFailed }
  } catch {
    await session.logout()
    throw error
  }
  await session.logout()
  #expect(session.phase == .signedOut)
  #expect(session.message == nil)
  #expect(store.credential == nil)
  #expect(realtime.state == .stopped)
}

@MainActor private func waitForLocalConnection(_ session: RealtimeSession) async throws {
  for _ in 0..<200 {
    if session.state == .connected { return }
    try await Task.sleep(for: .milliseconds(100))
  }
  throw LocalServerTestError.acceptanceFailed
}

private func localTestCode(_ secret: String) throws -> String {
  let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
  var bits = 0
  var buffer: UInt32 = 0
  var key = Data()
  for character in secret.uppercased().filter({ !$0.isWhitespace && $0 != "=" }) {
    guard let value = alphabet.firstIndex(of: character) else {
      throw LocalServerTestError.invalidSecret
    }
    buffer = (buffer << 5) | UInt32(value)
    bits += 5
    if bits >= 8 {
      bits -= 8
      key.append(UInt8((buffer >> bits) & 255))
    }
    buffer &= (1 << bits) - 1
  }
  guard !key.isEmpty, buffer == 0 else { throw LocalServerTestError.invalidSecret }
  var counter = (UInt64(Date().timeIntervalSince1970) / 30).bigEndian
  let message = withUnsafeBytes(of: &counter) { Data($0) }
  let digest = Array(
    HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
  let offset = Int(digest[digest.count - 1] & 15)
  let number = digest[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  return String(format: "%06u", (number & 0x7fff_ffff) % 1_000_000)
}
