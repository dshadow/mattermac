import MattermacCore
import SwiftUI

struct AuthenticationView: View {
  let session: AuthenticationSession
  @Environment(\.scenePhase) private var scenePhase
  @State private var confirmingLogout = false

  var body: some View {
    Group {
      switch session.phase {
      case .starting:
        ProgressView("Restoring session…")
      case .signedOut, .reauthenticationRequired:
        LoginView(session: session)
      case .verificationRequired, .cleanupRequired:
        VStack(spacing: 16) {
          Label(
            session.phase == .cleanupRequired ? "Finish signing out" : "Verify saved session",
            systemImage: "lock.shield"
          )
          .font(.title2)
          Text(session.message ?? "Checking your saved session…")
          if session.phase == .verificationRequired {
            Button("Retry") { Task { await session.restore() } }
              .disabled(session.isBusy)
          }
        }
      case .authenticated:
        VStack(alignment: .leading, spacing: 16) {
          Text("Signed in as \(session.user?.username ?? "")")
            .font(.title2)
          Text(session.serverAddress).foregroundStyle(.secondary)
          if let realtime = session.realtime { RealtimeView(realtime: realtime) }
          if let message = session.message { Text(message).foregroundStyle(.secondary) }
          Button("Check Session") { Task { await session.verify() } }
            .disabled(session.isBusy)
        }
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .toolbar {
      if session.phase != .starting && session.phase != .signedOut {
        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
          if session.logoutNeedsConfirmation {
            confirmingLogout = true
          } else {
            Task { await session.logout() }
          }
        }
        .disabled(session.isBusy)
      }
      if session.isBusy { ProgressView().controlSize(.small) }
    }
    .confirmationDialog(
      "Discard unsent content and sign out?", isPresented: $confirmingLogout,
      titleVisibility: .visible
    ) {
      Button("Discard and Sign Out", role: .destructive) {
        Task { await session.logout(discardUnsent: true) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes this account’s cache, drafts, pending messages and saved session. Downloaded files are kept."
      )
    }
    .task { await session.start() }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      // Check periodically while active; returning from sleep also checks immediately.
      while !Task.isCancelled {
        await session.verify()
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
      }
    }
  }
}
