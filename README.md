# Mattermac

A native, open-source Mattermost client for macOS, built with SwiftUI.
The goal is a lightweight app for everyday messaging that feels at home on your Mac.

**Early development:** the app currently opens a welcome window. Signing in,
channels, and messaging are not available yet. It is not ready for daily use.

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

Local builds use ad hoc signing by default; a paid Apple Developer account is not
required to try the app.

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

## License

Mattermac is licensed under the [MIT License](LICENSE).
