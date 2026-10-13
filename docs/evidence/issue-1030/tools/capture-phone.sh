#!/usr/bin/env bash
# #1030 (copied from the #1028 design round's tools) — deterministic simulator
# capture for the phone harness. The harness (`--design-1028 <state>`) is a
# LOCAL, uncommitted DEBUG patch (`capture-harness.patch.gz` beside this
# script); the shipped app has no such switch.
#
# Usage: capture-phone.sh <app-path> <udid> <out-dir> <label> [states...]
#   Each state is a DesignFixture1028 state (see `DesignFixture1028.swift`
#   inside capture-harness.patch.gz); append
#   "@bottom" to scroll the tab's content to its end (F5 evidence), or
#   "@progressor" to bring Force's Progressor card (the mascot) to the top.
# Captures every state in dark then light: <out-dir>/<label>-<state>-<scheme>.png
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
    STATE="${ENTRY%@*}"; EXTRA=()
    NAME="$STATE"
    if [[ "$ENTRY" == *@bottom ]]; then EXTRA+=(--design-1028-scroll bottom); NAME="$STATE-bottom"; fi
    if [[ "$ENTRY" == *@progressor ]]; then EXTRA+=(--design-1028-scroll progressor); NAME="$STATE-progressor"; fi
    # Launch, then prove the app is frontmost-running before the shutter: a
    # first launch after install can silently land on the home screen.
    for ATTEMPT in 1 2 3; do
      xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
      sleep 1
      if xcrun simctl launch "$UDID" "$BID" --design-1028 "$STATE" ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null 2>&1; then
        sleep 6
        if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BID"; then break; fi
      fi
      echo "retry $STATE ($SCHEME) attempt $ATTEMPT" >&2
    done
    xcrun simctl io "$UDID" screenshot "$OUT/$LABEL-$NAME-$SCHEME.png" >/dev/null 2>&1
    echo "$OUT/$LABEL-$NAME-$SCHEME.png"
  done
done
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
