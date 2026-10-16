import MattermacCore
import SwiftUI

@main
struct MattermacApp: App {
  @NSApplicationDelegateAdaptor(RealtimeLifecycle.self) private var lifecycle
  @State private var session: AuthenticationSession

  init() {
    #if DEBUG
      let localTesting = CommandLine.arguments.contains("--local-test-server")
    #else
      let localTesting = false
    #endif
    _session = State(
      initialValue: AuthenticationSession(
        store: KeychainSessionStore(localTesting: localTesting),
        realtime: RealtimeSession(allowInsecureLocalhost: localTesting),
        allowInsecureLocalhost: localTesting))
    KeychainContinuityProbe.runIfRequested()
    SessionStoreContinuityProbe.runIfRequested()
  }

  var body: some Scene {
    WindowGroup("Mattermac", id: "main") {
      AuthenticationView(session: session)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
          lifecycle.start(session.realtime)
          AppLogger.lifecycle.info("Main window appeared")
        }
    }
    .defaultSize(width: 960, height: 640)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check Session") { Task { await session.verify() } }
          .disabled(session.phase != .authenticated || session.isBusy)
      }
    }
  }
}
