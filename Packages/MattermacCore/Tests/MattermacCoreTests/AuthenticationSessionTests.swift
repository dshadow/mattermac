import Foundation
import Testing

@testable import MattermacCore

private let authUserJSON = #"{"id":"user1","username":"tester"}"#

@MainActor private final class MemoryCredentialStore: SessionCredentialStore {
  var record: SessionCredential?
  var failSave = false
  var failDelete = false
  var saves = 0
  func load() throws -> SessionCredential? { record }
  func save(_ credential: SessionCredential) throws {
    if failSave { throw CredentialStoreError.unavailable }
    record = credential
    saves += 1
  }
  func delete() throws {
    if failDelete { throw CredentialStoreError.unavailable }
    record = nil
  }
}

@MainActor private final class AccountDataFixture: AccountSessionData {
  var unsent = false
  var failReconcile = false
  var paused: [SessionAccount] = []
  var cleared: [SessionAccount] = []
  var reconciled: [SessionAccount] = []
  func hasUnsentContent(for account: SessionAccount) -> Bool { unsent }
  func pause(for account: SessionAccount) { paused.append(account) }
  func reconcile(for account: SessionAccount) async throws {
    if failReconcile { throw APIError.offline }
    reconciled.append(account)
  }
  func clear(for account: SessionAccount) async throws {
    cleared.append(account)
    unsent = false
  }
}

private actor SessionTransport: HTTPTransport {
  struct Step: Sendable {
    var status = 200
    var json = authUserJSON
    var headers: [String: String] = [:]
    var gate: SessionGate?
  }
  var steps: [Step]
  var requests: [URLRequest] = []
  init(_ steps: [Step]) { self.steps = steps }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !steps.isEmpty else { throw APIError.offline }
    let step = steps.removeFirst()
    if let gate = step.gate { await gate.suspend() }
    return HTTPResponse(
      data: Data(step.json.utf8),
      response: HTTPURLResponse(
        url: request.url!, statusCode: step.status, httpVersion: nil, headerFields: step.headers)!)
  }
}

private actor SessionGate {
  var entered = false
  var entryWaiter: CheckedContinuation<Void, Never>?
  var releaseWaiter: CheckedContinuation<Void, Never>?
  func suspend() async {
    await withCheckedContinuation {
      releaseWaiter = $0
      entered = true
      entryWaiter?.resume()
      entryWaiter = nil
    }
  }
  func waitForEntry() async {
    if entered { return }
    await withCheckedContinuation { entryWaiter = $0 }
  }
  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

@MainActor private func savedCredential() throws -> SessionCredential {
  SessionCredential(
    server: try MattermostServer("https://example.com/chat"), userID: "user1",
    token: try SessionToken("syntheticSessionSecret"))
}

@MainActor private func authSession(
  _ transport: SessionTransport, store: MemoryCredentialStore,
  data: AccountDataFixture = AccountDataFixture()
) -> AuthenticationSession {
  AuthenticationSession(store: store, accountData: data) {
    try MattermostAPIClient(server: $0, transport: transport, log: { _ in })
  }
}

@MainActor private func signIn(_ session: AuthenticationSession) async {
  await session.login(
    address: "https://example.com/chat", loginID: "tester", password: "syntheticPassword",
    mfaCode: "001234")
}

@Test @MainActor func loginPersistsOnlySessionAndRestoresAfterRestart() async throws {
  let store = MemoryCredentialStore()
  let transport = SessionTransport([
    .init(headers: ["Token": "syntheticSessionSecret"]), .init(),
  ])
  let session = authSession(transport, store: store)
  await session.start()
  #expect(session.phase == .signedOut)
  await signIn(session)
  #expect(session.phase == .authenticated)
  #expect(store.saves == 1)
  let encoded = String(decoding: try JSONEncoder().encode(#require(store.record)), as: UTF8.self)
  #expect(!encoded.contains("syntheticPassword"))
  #expect(!encoded.contains("001234"))
  let reopened = authSession(transport, store: store)
  await reopened.start()
  #expect(reopened.phase == .authenticated)
  #expect(reopened.user?.id == "user1")
  let requests = await transport.requests
  #expect(requests.last?.url?.path == "/chat/api/v4/users/me")
  #expect(
    requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer syntheticSessionSecret")
}

@Test @MainActor func localHTTPRequiresOptInAcrossSessionLifecycle() async throws {
  let store = MemoryCredentialStore()
  let transport = SessionTransport([
    .init(headers: ["Token": "syntheticSessionSecret"]), .init(), .init(), .init(),
  ])
  func session(local: Bool) -> AuthenticationSession {
    AuthenticationSession(store: store, allowInsecureLocalhost: local) {
      try MattermostAPIClient(server: $0, transport: transport, log: { _ in })
    }
  }
  let normal = session(local: false)
  await normal.start()
  await normal.login(
    address: "http://127.0.0.1:8065", loginID: "test", password: "fake", mfaCode: "")
  #expect(normal.phase == .signedOut)
  #expect(await transport.requests.isEmpty)
  let local = session(local: true)
  await local.start()
  await local.login(address: "http://example.com", loginID: "test", password: "fake", mfaCode: "")
  #expect(local.phase == .signedOut)
  #expect(await transport.requests.isEmpty)
  await local.login(
    address: "http://127.0.0.1:8065", loginID: "test", password: "fake", mfaCode: "")
  #expect(local.phase == .authenticated)
  let restored = session(local: true)
  await restored.start()
  #expect(restored.phase == .authenticated)
  await restored.verify()
  #expect(restored.message == nil)
  await restored.logout()
  #expect(restored.phase == .signedOut)
  #expect(restored.message == nil)
  #expect(store.record == nil)
  #expect(await transport.requests.count == 4)
}

@Test @MainActor func offlineRestorePreservesCredentialAndHidesAccountData() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let session = authSession(SessionTransport([]), store: store)
  await session.start()
  #expect(session.phase == .verificationRequired)
  #expect(session.user == nil)
  #expect(store.record != nil)
  await #expect(throws: AuthenticationError.sessionUnavailable) {
    try await session.perform { _, _ in true }
  }
}

@Test @MainActor func expiredRestoreRequiresSameAccountAndReconcilesBeforeResuming() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let data = AccountDataFixture()
  data.unsent = true
  let transport = SessionTransport([
    .init(status: 401),
    .init(json: #"{"id":"user2","username":"other"}"#, headers: ["Token": "wrongAccount"]),
    .init(json: "{}"),
    .init(headers: ["Token": "renewedSession"]),
  ])
  let session = authSession(transport, store: store, data: data)
  await session.start()
  #expect(session.phase == .reauthenticationRequired)
  #expect(data.unsent)
  #expect(data.paused.count == 1)
  await signIn(session)
  #expect(session.phase == .reauthenticationRequired)
  #expect(store.record?.userID == "user1")
  #expect(data.reconciled.isEmpty)
  #expect(await transport.requests.last?.url?.path == "/chat/api/v4/users/logout")
  await signIn(session)
  #expect(session.phase == .authenticated)
  #expect(data.reconciled.count == 1)
  #expect(data.unsent)
}

@Test @MainActor func authenticated401PausesWorkWithoutDeletingDrafts() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let data = AccountDataFixture()
  data.unsent = true
  let session = authSession(
    SessionTransport([.init(), .init(status: 401)]), store: store, data: data)
  await session.start()
  await session.verify()
  #expect(session.phase == .reauthenticationRequired)
  #expect(session.user == nil)
  #expect(data.unsent)
  #expect(data.cleared.isEmpty)
  #expect(store.record != nil)
}

@Test @MainActor func logoutConfirmationCancelPreservesEverythingThenConfirmedCleanupRuns()
  async throws
{
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let data = AccountDataFixture()
  data.unsent = true
  let transport = SessionTransport([.init(), .init(json: "{}")])
  let session = authSession(transport, store: store, data: data)
  await session.start()
  #expect(session.logoutNeedsConfirmation)
  await session.logout()
  #expect(session.phase == .authenticated)
  #expect(await transport.requests.count == 1)
  #expect(data.cleared.isEmpty)
  await session.logout(discardUnsent: true)
  #expect(session.phase == .signedOut)
  #expect(store.record == nil)
  #expect(data.cleared.count == 1)
  #expect(!data.unsent)
  #expect(session.account == nil)
}

@Test @MainActor func failedServerLogoutStillDeletesLocalCredentials() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let session = authSession(SessionTransport([.init(), .init(status: 503)]), store: store)
  await session.start()
  await session.logout()
  #expect(session.phase == .signedOut)
  #expect(store.record == nil)
  #expect(session.message?.contains("revocation") == true)
}

@Test @MainActor func failedKeychainDeleteBlocksAccountSwitchUntilCleanupSucceeds() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  store.failDelete = true
  let session = authSession(SessionTransport([.init(), .init(json: "{}")]), store: store)
  await session.start()
  await session.logout()
  #expect(session.phase == .cleanupRequired)
  await session.restore()
  #expect(session.phase == .cleanupRequired)
  #expect(session.user == nil)
  #expect(store.record != nil)
  await signIn(session)
  #expect(store.saves == 0)
  store.failDelete = false
  await session.logout()
  #expect(session.phase == .signedOut)
  #expect(store.record == nil)
}

@Test @MainActor func failedKeychainSaveRevokesIssuedSessionAndRedactsErrors() async throws {
  let store = MemoryCredentialStore()
  store.failSave = true
  let transport = SessionTransport([
    .init(headers: ["Token": "syntheticSessionSecret"]), .init(json: "{}"),
  ])
  let session = authSession(transport, store: store)
  await session.start()
  await signIn(session)
  #expect(session.phase == .signedOut)
  #expect(store.record == nil)
  #expect(await transport.requests.count == 2)
  #expect(session.message?.contains("Keychain") == true)
  #expect(session.message?.contains("synthetic") == false)
}

@Test @MainActor func reconciliationFailureKeepsSendsPaused() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let data = AccountDataFixture()
  data.failReconcile = true
  let session = authSession(SessionTransport([.init()]), store: store, data: data)
  await session.start()
  #expect(session.phase == .verificationRequired)
  #expect(session.user == nil)
  await #expect(throws: AuthenticationError.sessionUnavailable) {
    try await session.perform { _, _ in true }
  }
}

@Test @MainActor func lateResponsesCannotEscapeAfterLogout() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let session = authSession(SessionTransport([.init(), .init(json: "{}")]), store: store)
  await session.start()
  let gate = SessionGate()
  let pending = Task {
    try await session.perform { _, _ in
      await gate.suspend()
      return "old account data"
    }
  }
  await gate.waitForEntry()
  await session.logout()
  await gate.release()
  await #expect(throws: AuthenticationError.staleSession) { try await pending.value }
  #expect(session.phase == .signedOut)
}

@Test @MainActor func concurrentLoginIsRejectedDuringRestore() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let gate = SessionGate()
  let transport = SessionTransport([.init()])
  // Hold reconciliation open to test the entire authentication attempt, including local work.
  let data = SuspendingAccountData(gate: gate)
  let held = AuthenticationSession(store: store, accountData: data) {
    try MattermostAPIClient(server: $0, transport: transport, log: { _ in })
  }
  let pending = Task { await held.start() }
  await gate.waitForEntry()
  await signIn(held)
  #expect(store.saves == 0)
  #expect(await transport.requests.count == 1)
  await gate.release()
  await pending.value
  #expect(held.phase == .authenticated)
}

@MainActor private struct SuspendingAccountData: AccountSessionData {
  let gate: SessionGate
  func hasUnsentContent(for account: SessionAccount) -> Bool { false }
  func pause(for account: SessionAccount) {}
  func reconcile(for account: SessionAccount) async throws { await gate.suspend() }
  func clear(for account: SessionAccount) async throws {}
}

@Test @MainActor func credentialDescriptionsNeverRevealSecretsOrIdentity() throws {
  let credential = try savedCredential()
  #expect(String(describing: credential) == "SessionCredential(<redacted>)")
  #expect(String(reflecting: credential) == "SessionCredential(<redacted>)")
  #expect(Mirror(reflecting: credential).children.isEmpty)
}

@Test @MainActor func changedServerIdentityLocksPreviouslyAuthenticatedSession() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let session = authSession(
    SessionTransport([.init(), .init(json: #"{"id":"user2","username":"other"}"#)]),
    store: store)
  await session.start()
  await session.verify()
  #expect(session.phase == .reauthenticationRequired)
  #expect(session.user == nil)
  #expect(store.record?.userID == "user1")
}

@Test @MainActor func oldVerificationCannotChangeNewSessionOrItsMessage() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let gate = SessionGate()
  let session = authSession(
    SessionTransport([
      .init(), .init(status: 401, gate: gate), .init(json: "{}"),
      .init(headers: ["Token": "newSession"]),
    ]), store: store)
  await session.start()
  let checking = Task { await session.verify() }
  await gate.waitForEntry()
  await session.logout()
  await signIn(session)
  #expect(session.phase == .authenticated)
  await gate.release()
  await checking.value
  #expect(session.phase == .authenticated)
  #expect(session.message == nil)
  #expect(session.user?.id == "user1")
}

@Test @MainActor func reauthenticationCannotSwitchServers() async throws {
  let store = MemoryCredentialStore()
  store.record = try savedCredential()
  let transport = SessionTransport([.init(status: 401)])
  let session = authSession(transport, store: store)
  await session.start()
  await session.login(
    address: "https://other.example.com", loginID: "tester", password: "secret", mfaCode: "")
  #expect(session.phase == .reauthenticationRequired)
  #expect(await transport.requests.count == 1)
  #expect(store.saves == 0)
}

@Test @MainActor func badPasswordOrMFADoesNotPersistOrExposeRemoteError() async {
  let store = MemoryCredentialStore()
  let transport = SessionTransport([
    .init(status: 401, json: #"{"message":"secret remote details"}"#)
  ])
  let session = authSession(transport, store: store)
  await session.start()
  await signIn(session)
  #expect(session.phase == .signedOut)
  #expect(store.record == nil)
  #expect(session.message?.contains("MFA") == true)
  #expect(session.message?.contains("secret") == false)
  #expect(await transport.requests.count == 1)
}

@Test @MainActor func nativeLoginRejectsPlainHTTPWithoutNetworkRequest() async {
  let transport = SessionTransport([])
  let session = authSession(transport, store: MemoryCredentialStore())
  await session.start()
  await session.login(
    address: "http://localhost:8065", loginID: "tester", password: "secret", mfaCode: "")
  #expect(session.phase == .signedOut)
  #expect(await transport.requests.isEmpty)
  #expect(session.message?.contains("HTTPS") == true)
}
