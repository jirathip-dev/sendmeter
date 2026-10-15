#!/usr/bin/env bash
# #1038 design round — deterministic simulator capture for the phone harness.
#
# Usage: capture-phone.sh <app-path> <udid> <out-dir> <label> [states...]
#   Each state is a DesignFixture1038 state (see
#   native/SendmeterNative/Sources/App/DesignFixture1038.swift); append
#   "@guided=work|rest|complete" to capture the guided full screen through its
#   own #938 harness instead of the tab shell.
# Captures every state in dark then light: <out-dir>/<label>-<state>-<scheme>.png
#
# Before/after: the SAME script runs against the base build with the base's own
# fixture states (force-handsfree-armed, force-recording), so the two rounds are
# captured by one tool with one status bar.
set -euo pipefail
APP="$1"; UDID="$2"; OUT="$3"; LABEL="$4"; shift 4
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
mkdir -p "$OUT"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
for SCHEME in dark light; do
  xcrun simctl ui "$UDID" appearance "$SCHEME"
  for ENTRY in "$@"; do
    STATE="${ENTRY%@*}"
    ARGS=(--design-1038 "$STATE")
    NAME="$STATE"
    if [[ "$ENTRY" == *"@guided="* ]]; then
      STAGE="${ENTRY##*@guided=}"
      ARGS=(--guided-force-fixture "$STAGE")
      NAME="guided-fullscreen-$STAGE"
    fi
    # Launch, then prove the app is frontmost-running before the shutter: a
    # first launch after install can silently land on the home screen.
    for ATTEMPT in 1 2 3; do
      xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
      sleep 1
      if xcrun simctl launch "$UDID" "$BID" "${ARGS[@]}" >/dev/null 2>&1; then
        sleep 7
        if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BID"; then break; fi
      fi
      echo "retry $STATE ($SCHEME) attempt $ATTEMPT" >&2
    done
    xcrun simctl io "$UDID" screenshot "$OUT/$LABEL-$NAME-$SCHEME.png" >/dev/null 2>&1
    echo "$OUT/$LABEL-$NAME-$SCHEME.png"
  done
done
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
