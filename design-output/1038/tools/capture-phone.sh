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
for SCHEME in ${SCHEMES:-dark light}; do
  xcrun simctl ui "$UDID" appearance "$SCHEME"
  for ENTRY in "$@"; do
    STATE="${ENTRY%@*}"
    ARGS=(--design-1038 "$STATE")
    NAME="$STATE"
    if [[ "$ENTRY" == *"@guided="* ]]; then
      STAGE="${ENTRY##*@guided=}"
      # The #938 harness parses ONE argument `--guided-force-fixture=<stage>`;
      # passed as two words it silently falls back to its rest stage.
      ARGS=("--guided-force-fixture=$STAGE")
      NAME="guided-fullscreen-$STAGE"
    fi
    # Launch, then prove the app is frontmost-running before the shutter: a
    # first launch after install can silently land on the home screen.
    # `simctl launch` prints "<bundle-id>: <pid>"; that pid must still be a
    # live process after the settle wait (a crash or a bounce to the home
    # screen fails the check). `launchctl procinfo` exits 0 even for a dead
    # pid, so the check reads its output ("program path" only when alive).
    LIVE=0
    for ATTEMPT in 1 2 3; do
      xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
      sleep 1
      LAUNCHED=$(xcrun simctl launch "$UDID" "$BID" "${ARGS[@]}" 2>/dev/null || true)
      PID="${LAUNCHED##*: }"
      if [[ "$PID" =~ ^[0-9]+$ ]]; then
        sleep 7
        INFO=$(xcrun simctl spawn "$UDID" launchctl procinfo "$PID" 2>/dev/null || true)
        # (no pipe into grep -q: under pipefail its early exit SIGPIPEs
        # procinfo and the pipeline "fails" on a live process)
        if [[ "$INFO" == *"program path"* ]]; then
          LIVE=1
          break
        fi
      fi
      echo "retry $STATE ($SCHEME) attempt $ATTEMPT" >&2
    done
    # Fail closed: never shutter a screen the app was not proven to own.
    if [[ "$LIVE" != 1 ]]; then
      echo "FAIL $STATE ($SCHEME): app not running after 3 launches" >&2
      exit 1
    fi
    xcrun simctl io "$UDID" screenshot "$OUT/$LABEL-$NAME-$SCHEME.png" >/dev/null 2>&1
    echo "$OUT/$LABEL-$NAME-$SCHEME.png"
  done
done
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
