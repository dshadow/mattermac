#!/usr/bin/env bash
# Opt-in, real-server acceptance. Only the existing local test account is used.
set -euo pipefail
set +x
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
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
export MATTERMAC_LOCAL_INTEGRATION=1
rtk proxy swift test --package-path Packages/MattermacCore --scratch-path tmp/PackageBuild \
  -Xswiftc -warnings-as-errors --filter localComposeAuthenticationAndRealtime
# Xcode forwards TEST_RUNNER_ variables to the hosted test process without the prefix.
export TEST_RUNNER_MATTERMAC_LOCAL_INTEGRATION=1
rtk proxy xcodebuild -quiet -project Mattermac.xcodeproj -scheme Mattermac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath tmp/TestDerivedData ENABLE_HARDENED_RUNTIME=NO test
