#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
rtk proxy xcrun swift-format lint --strict --recursive Mattermac MattermacTests Packages/MattermacCore/Package.swift Packages/MattermacCore/Sources Packages/MattermacCore/Tests
rtk proxy swift test --package-path Packages/MattermacCore --scratch-path tmp/PackageBuild -Xswiftc -warnings-as-errors
# XCTest loads ad hoc package frameworks into the self-signed host. Keep this
# test-only runtime exception and its products separate from normal app builds.
rtk proxy xcodebuild -project Mattermac.xcodeproj -scheme Mattermac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath tmp/TestDerivedData ENABLE_HARDENED_RUNTIME=NO test
rtk proxy xcodebuild -project Mattermac.xcodeproj -scheme Mattermac \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath tmp/DerivedData build
rtk git diff --check
