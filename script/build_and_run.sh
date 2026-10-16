#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|--logs|--telemetry|--verify|--local-test) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--local-test]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ "$MODE" == --local-test ]]; then
  rtk docker compose up -d
  ready=false
  for ((attempt = 0; attempt < 60; attempt++)); do
    if rtk proxy curl --fail --silent --output /dev/null \
      --connect-timeout 1 --max-time 2 http://127.0.0.1:8065/api/v4/system/ping; then
      ready=true
      break
    fi
    rtk proxy sleep 1
  done
  if [[ "$ready" != true ]]; then
    echo "Local Mattermost did not become ready on port 8065." >&2
    exit 1
  fi
fi
rtk proxy pkill -x Mattermac >/dev/null 2>&1 || true
rtk proxy xcodebuild -project Mattermac.xcodeproj -scheme Mattermac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath tmp/DerivedData build
APP_BUNDLE="$ROOT_DIR/tmp/DerivedData/Build/Products/Debug/Mattermac.app"

case "$MODE" in
  --debug) rtk proxy lldb -- "$APP_BUNDLE/Contents/MacOS/Mattermac" ;;
  --logs|--telemetry)
    rtk proxy open -n "$APP_BUNDLE"
    if [[ "$MODE" == --telemetry ]]; then
      rtk proxy /usr/bin/log stream --info --style compact \
        --predicate 'subsystem == "io.github.dshadow.mattermac"'
    else
      rtk proxy /usr/bin/log stream --info --style compact --predicate 'process == "Mattermac"'
    fi
    ;;
  --verify)
    rtk proxy open -n "$APP_BUNDLE"
    rtk proxy sleep 2
    rtk proxy pgrep -x Mattermac
    ;;
  run) rtk proxy open -n "$APP_BUNDLE" ;;
  --local-test)
    rtk proxy open -n "$APP_BUNDLE" --args --local-test-server
    echo "Local test mode: sign in at http://127.0.0.1:8065 using your local test account."
    ;;
esac
