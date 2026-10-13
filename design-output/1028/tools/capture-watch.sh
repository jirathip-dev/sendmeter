#!/usr/bin/env bash
# #1028 deterministic Watch capture: real watch hierarchy, ScreenshotFixtures
# states (`-FASTLANE_SNAPSHOT YES` gate), 9:41 status bar, gauge routed via
# `-sendmeter-fixture-route force` for force states.
#   capture-watch.sh <app> <udid> <outdir> <prefix> <state[@force]>...
set -euo pipefail
APP="$1"; U="$2"; OUT="$3"; PFX="$4"; shift 4
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
mkdir -p "$OUT"
xcrun simctl boot "$U" 2>/dev/null || true
xcrun simctl bootstatus "$U" -b >/dev/null
xcrun simctl status_bar "$U" override --time 9:41 >/dev/null 2>&1 || true
xcrun simctl install "$U" "$APP"
for entry in "$@"; do
  st="${entry%@*}"; EXTRA=()
  name="$st"
  if [[ "$entry" == *@force ]]; then EXTRA=(-sendmeter-fixture-route force); name="$st-gauge"; fi
  xcrun simctl terminate "$U" "$BID" >/dev/null 2>&1 || true
  xcrun simctl launch "$U" "$BID" -FASTLANE_SNAPSHOT YES -sendmeter-fixture "$st" ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null
  sleep 7
  xcrun simctl io "$U" screenshot "$OUT/$PFX-watch-$name.png" >/dev/null 2>&1
  echo "$OUT/$PFX-watch-$name.png"
done
xcrun simctl terminate "$U" "$BID" >/dev/null 2>&1 || true
