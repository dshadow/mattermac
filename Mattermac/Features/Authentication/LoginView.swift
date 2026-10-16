import MattermacCore
import SwiftUI

struct LoginView: View {
  let session: AuthenticationSession
  @State private var address = ""
  @State private var loginID = ""
  @State private var password = ""
  @State private var mfaCode = ""
  @FocusState private var focus: Field?

  private enum Field { case server, username, password, mfa }

  var body: some View {
    VStack(spacing: 20) {
      Label("Sign in to Mattermac", systemImage: "bubble.left.and.bubble.right")
        .font(.title)
      if session.allowInsecureLocalhost {
        Text("Local test mode · HTTP allowed only on loopback. Use a test account.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if session.phase == .reauthenticationRequired {
        Text("Sign in to the same account to resume your session.")
          .foregroundStyle(.secondary)
      }
      Form {
        TextField("Server URL", text: $address, prompt: Text("https://chat.example.com"))
          .textContentType(.URL)
          .focused($focus, equals: .server)
          .disabled(session.phase == .reauthenticationRequired)
        TextField("Username or email", text: $loginID)
          .textContentType(.username)
          .focused($focus, equals: .username)
        SecureField("Password", text: $password)
          .textContentType(.password)
          .focused($focus, equals: .password)
        SecureField("MFA code (if enabled)", text: $mfaCode)
          .textContentType(.oneTimeCode)
          .focused($focus, equals: .mfa)
      }
      .disabled(session.isBusy)
      .onSubmit { signIn() }
      if let message = session.message {
        Text(message)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("authenticationMessage")
      }
      Button("Sign In", action: signIn)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
      Text("Your session is stored in macOS Keychain. Passwords and MFA codes are never saved.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: 440)
    .onAppear {
      address = session.serverAddress
      if address.isEmpty && session.allowInsecureLocalhost { address = "http://127.0.0.1:8065" }
      focus = address.isEmpty ? .server : .username
    }
    .onDisappear {
      password = ""
      mfaCode = ""
    }
  }

  private var canSubmit: Bool {
    !session.isBusy && !address.isEmpty && !loginID.isEmpty && !password.isEmpty
  }

  private func signIn() {
    guard canSubmit else { return }
    let submittedPassword = password
    let submittedCode = mfaCode
    password = ""
    mfaCode = ""
    Task {
      await session.login(
        address: address, loginID: loginID, password: submittedPassword, mfaCode: submittedCode)
      if session.phase != .authenticated { focus = .password }
    }
  }
}
