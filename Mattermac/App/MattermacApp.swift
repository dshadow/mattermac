import SwiftUI

@main
struct MattermacApp: App {
  init() {
    KeychainContinuityProbe.runIfRequested()
  }

  var body: some Scene {
    WindowGroup("Mattermac", id: "main") {
      WelcomeView()
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
          AppLogger.lifecycle.info("Main window appeared")
        }
    }
    .defaultSize(width: 960, height: 640)
  }
}
