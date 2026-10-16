# Mattermac

A native, open-source Mattermost client for macOS, built with SwiftUI.
The goal is a lightweight app for everyday messaging that feels at home on your Mac.

**Early development:** native username/password sign-in, optional MFA, saved
sessions and sign-out are available. A read-only channel picker shows the latest
200 messages, with live edits, deletions, reactions and reconnect recovery. Recent
messages are cached across restarts, with configurable retention in Settings.
It is not ready for daily use.

Mattermac is an independent project, not affiliated with Mattermost, Inc.

## Getting started

Mattermac is currently available as source code. Packaged app downloads are planned
for a later stage.

To build and try it, you need:

- An Apple Silicon Mac running macOS 27.0 or later.
- Xcode 27.0 with the macOS SDK and Swift 6.4.

1. Download or clone this repository.
2. Open `Mattermac.xcodeproj` in Xcode.
3. Select the **Mattermac** scheme and **My Mac** destination.
4. Choose **Product → Run** (`⌘R`).

Local builds use the stable self-signed `Mattermac Local` identity. Set up signing
as described in the [signing guide](docs/signing.md); a paid Apple Developer
account is not required. Keep the same identity for Keychain access across builds.

Enter your server's HTTPS base URL, including any deployment subpath, then your
Mattermost username or email and password. If MFA is enabled, enter a fresh
authentication code. LDAP credentials are verified by your Mattermost server.
SSO browser flows are not supported yet.

The session token and account identity are stored in macOS Keychain; passwords
and MFA codes are never saved. On reopening, the app verifies the saved session
with the server. An expired session requires signing in to the same account.
Sign out before switching accounts. Sign-out removes local credentials and
attempts server revocation; if offline, server revocation cannot be confirmed.

Choose a channel after signing in. Connection status shows when recent messages
have recovered after a network interruption or wake. Previously opened messages
load from local cache after session verification, followed by server updates.
Settings defaults to 30 days of inactive cache retention. Local data relies on
macOS permissions and your FileVault settings; it is not independently encrypted.
Sign-out removes account cache and unsent work after confirmation. Older history,
sending, attachments and desktop notifications are still planned.

## Development

The app lives in `Mattermac/`, shared logic in `Packages/MattermacCore/`, and
app tests in `MattermacTests/`. Assets are in `Mattermac/Resources/`.
There are currently no third-party dependencies.

Run these commands from the repository root with Xcode selected as the active
developer directory.

Build the app:

```sh
xcodebuild -project Mattermac.xcodeproj -scheme Mattermac -destination 'platform=macOS,arch=arm64' -derivedDataPath tmp/DerivedData build
```

Run app tests:

```sh
xcodebuild -project Mattermac.xcodeproj -scheme Mattermac -destination 'platform=macOS,arch=arm64' -derivedDataPath tmp/DerivedData test
```

Run shared logic tests separately:

```sh
swift test --package-path Packages/MattermacCore --scratch-path tmp/PackageBuild -Xswiftc -warnings-as-errors
```

Use two-space indentation and follow `.swift-format`. Check formatting with
Xcode’s bundled formatter:

```sh
xcrun swift-format lint --strict --recursive Mattermac MattermacTests Packages/MattermacCore/Package.swift Packages/MattermacCore/Sources Packages/MattermacCore/Tests
```

To apply formatting, replace `lint --strict` with `format --in-place`.
Swift warnings fail builds. Before opening a pull request, run the tests and
formatter, describe your changes, and include screenshots for UI changes.

## Roadmap and documentation

- [Roadmap](TODO.md): planned features and implementation tasks.
- [Progress](PROGRESS.md): current work and validation results.
- [Architecture decisions](DECISIONS.md): design choices and rationale.
- [Signing guide](docs/signing.md): signing setup and credential persistence requirements.
- [Real-time synchronization](docs/realtime.md): connection lifecycle and recovery boundaries.
- [Local persistence](docs/persistence.md): cache retention, migrations and durable unsent work.

## License

Mattermac is licensed under the [MIT License](LICENSE).
