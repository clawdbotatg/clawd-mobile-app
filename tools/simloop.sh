#!/usr/bin/env bash
# Autonomous simulator loop: build ClawdChat, install + launch it in an iOS
# simulator, and grab a screenshot so an agent can *see* the running app.
#
#   tools/simloop.sh [screenshot.png]
#
# Env: SIM_NAME to prefer a specific device (default: newest iPhone sim).
# Requires full Xcode (xcodebuild + simctl). For tap/type control on top of
# this, install idb: `brew install idb-companion && pipx install fb-idb`.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/clawdchat-sim.png}"
BUNDLE_ID="com.clawd.chat"

UDID=$(xcrun simctl list devices available -j | SIM_NAME="${SIM_NAME:-}" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
phones = [(d["name"], d["udid"])
          for ds in data["devices"].values()
          for d in ds if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not phones:
    sys.exit("no available iPhone simulators — install an iOS runtime: xcodebuild -downloadPlatform iOS")
want = os.environ.get("SIM_NAME")
match = [u for n, u in phones if n == want]
print(match[0] if match else phones[-1][1])
')
echo "simulator: $UDID"

xcodebuild -project ClawdChat.xcodeproj -scheme ClawdChat \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build \
  -quiet build

xcrun simctl bootstatus "$UDID" -b   # boots if needed, waits until ready
xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/ClawdChat.app
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 4  # let the mock "download" finish and first frame settle
xcrun simctl io "$UDID" screenshot "$OUT"
echo "screenshot: $OUT"
