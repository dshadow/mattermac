import SwiftUI

struct WelcomeView: View {
  var body: some View {
    ContentUnavailableView {
      Label("Welcome to Mattermac", systemImage: "bubble.left.and.bubble.right")
    } description: {
      Text("A native Mattermost client for macOS. Server sign-in is coming next.")
    }
  }
}
