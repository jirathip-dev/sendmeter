#!/usr/bin/env bash
# #1031 RED probes: each mutation reverts ONE rule and must turn its focused
# test RED (non-zero exit); restoring must bring it back GREEN.
#
# Usage (repo root): bash docs/evidence/issue-1031/tools/red-probes.sh <probe> <log-dir>
#   probes: core-p11 core-p9 core-rule1 core-rule2 core-rule3
#           app-rule1 app-rule2 app-rule3 app-p11 ui-clearance
# App/UI probes need DD=<derived data> and run `xcodebuild test` under
# `hermes-sim-task` on a fresh temporary simulator of DEVICE_TYPE (default
# iPhone SE 3rd generation, the brief's clearance device). One xcodebuild at
# a time host-wide.
set -uo pipefail

PROBE="$1"
LOGS="$2"
ROOT="$(git rev-parse --show-toplevel)"
PKG="$ROOT/native/SendmeterNative"
mkdir -p "$LOGS"

mutate() { # file python-replace-old python-replace-new
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
assert text.count(old) == 1, f"mutation anchor not unique in {path}: {old!r}"
open(path, "w").write(text.replace(old, new))
PY
}

restore() { git -C "$ROOT" checkout -- "$1"; }

core_probe() { # file old new filter
  mutate "$PKG/$1" "$2" "$3" || exit 2
  swift test --package-path "$PKG" --filter "$4" > "$LOGS/red-$PROBE.log" 2>&1
  local red=$?
  restore "$PKG/$1"
  swift test --package-path "$PKG" --filter "$4" > "$LOGS/green-$PROBE.log" 2>&1
  local green=$?
  echo "probe=$PROBE red_exit=$red green_exit=$green"
}

xc_probe() { # file old new only-testing
  mutate "$PKG/$1" "$2" "$3" || exit 2
  (cd "$PKG" && hermes-sim-task --device-type "$DEVICE_TYPE" --xcodebuild -- test \
    -project SendmeterNative.xcodeproj -scheme SendmeterNative \
    -destination "platform=iOS Simulator,name=any" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
    -only-testing:"$4") > "$LOGS/red-$PROBE.log" 2>&1
  local red=$?
  restore "$PKG/$1"
  echo "probe=$PROBE red_exit=$red (GREEN: the unmutated suite run)"
}

AR=Sources/Core/ForceAutoReconnect.swift
DEVICE_TYPE="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation}"
case "$PROBE" in
  core-p11)
    core_probe Sources/Core/ForceBarPolicy.swift \
      'return make(connectionLostWord, .attention' 'return make(disconnectedWord, .attention' \
      ForceBarPolicyTests/testInterruptedSaysConnectionLost ;;
  core-p9)
    core_probe Sources/Core/ForceBarPolicy.swift \
      'recording && screenHeight > 0' 'screenHeight > 0' \
      ForceBarPolicyTests/testCompactHeightCollapsesTheTitleOnlyWhileRecording ;;
  core-rule1)
    core_probe "$AR" 'case .disconnected, .interrupted:
            return true' 'case .disconnected, .interrupted:
            return false' \
      ForceAutoReconnectPolicyTests/testReconnectsOnEnteringForceAndOnForeground ;;
  core-rule2)
    core_probe "$AR" 'guard !input.userDisconnected else { return false }' '' \
      ForceAutoReconnectPolicyTests/testDoesNotReconnectAfterAUserDisconnect ;;
  core-rule3)
    core_probe "$AR" 'guard !input.sessionActive else { return false }' '' \
      ForceAutoReconnectPolicyTests/testDoesNotReconnectMidSession ;;
  app-rule1)
    xc_probe Sources/App/AppModel.swift \
      '            autoReconnectProgressor(.foreground)
' '' \
      SendmeterNativeTests/ForceAutoReconnectAppTests/testForegroundOnForceReconnectsThroughScenePhase ;;
  app-rule2)
    xc_probe Sources/App/AppModel.swift \
      '        userDisconnectedProgressor = true
        progressorConnectionLost = false' '        progressorConnectionLost = false' \
      SendmeterNativeTests/ForceAutoReconnectAppTests/testUserDisconnectStopsAutoReconnectUntilTheNextConnect ;;
  app-rule3)
    xc_probe Sources/App/AppModel.swift \
      'sessionActive: forceModel.guidedProtocolActive || handsFree.isArmed || handsFree.isMeasuring' \
      'sessionActive: false' \
      SendmeterNativeTests/ForceAutoReconnectAppTests/testGuidedProtocolBlocksAutoReconnect ;;
  app-p11)
    xc_probe Sources/App/AppModel.swift \
      'return device == .interrupted && !progressorConnectionLost ? .disconnected : device' \
      'return device' \
      SendmeterNativeTests/ForceAutoReconnectAppTests/testOnlyADroppedLiveLinkReadsAsConnectionLost ;;
  ui-clearance)
    # F5 regression: the bar floats in an overlay instead of the bottom
    # safe-area inset, so the scroll content runs on under it.
    xc_probe Sources/Features/Force/ForceView.swift \
      '.safeAreaInset(edge: .bottom, spacing: 0) {
                forceBottomBar' '.overlay(alignment: .bottom) {
                forceBottomBar' \
      SendmeterNativeUITests/TabBarClearanceUITests ;;
  *) echo "unknown probe: $PROBE" >&2; exit 2 ;;
esac
