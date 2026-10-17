import MattermacCore
import SwiftUI

@main
struct MattermacApp: App {
  @NSApplicationDelegateAdaptor(RealtimeLifecycle.self) private var lifecycle
  @State private var session: AuthenticationSession
  @State private var persistence: AccountPersistence

  init() {
    #if DEBUG
      let localTesting = CommandLine.arguments.contains("--local-test-server")
      let storagePath = localTesting ? "MattermacLocalTest/Accounts" : "Mattermac/Accounts"
    #else
      let localTesting = false
      let storagePath = "Mattermac/Accounts"
    #endif
    let persistence = AccountPersistence(
      root: URL.applicationSupportDirectory.appendingPathComponent(
        storagePath, isDirectory: true))
    _persistence = State(initialValue: persistence)
    _session = State(
      initialValue: AuthenticationSession(
        store: KeychainSessionStore(localTesting: localTesting),
        accountData: persistence,
        realtime: RealtimeSession(storage: persistence, allowInsecureLocalhost: localTesting),
        allowInsecureLocalhost: localTesting))
    KeychainContinuityProbe.runIfRequested()
    SessionStoreContinuityProbe.runIfRequested()
  }

  var body: some Scene {
    WindowGroup("Mattermac", id: "main") {
      AuthenticationView(session: session)
        .frame(minWidth: 760, minHeight: 420)
        .onAppear {
          lifecycle.start(session.realtime)
          AppLogger.lifecycle.info("Main window appeared")
        }
    }
    .defaultSize(width: 960, height: 640)
    .commands {
      WorkspaceCommands()
      CommandGroup(after: .appInfo) {
        Button("Check Session") { Task { await session.verify() } }
          .disabled(session.phase != .authenticated || session.isBusy)
      }
    }
    Settings {
      CacheSettingsView(
        persistence: persistence,
        activeChannelID: session.realtime?.synchronization.selectedChannelID)
    }
  }
}
