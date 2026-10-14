#!/usr/bin/env bash
# #1032 before/after simulator captures (SE + 17 Pro, dark + light).
#
# The harness is LOCAL ONLY (apply-harness.py = #1031's DEBUG
# `--design-1028 <state>` fixture plus the #1032 states); it is applied to
# throwaway worktrees, never to the lane branch:
#   before = origin/staging at the lane base
#   after  = the lane head under test
# Each capture runs on a temporary simulator owned by `hermes-sim-task`
# (created, used, deleted), so no shared device is touched.
#
# Usage (repo root): capture-all.sh <before-tree> <after-tree> <capture-root>
# Writes <capture-root>/{before,after}/{se,17pro}/<label>-<state>-<scheme>.png
set -euo pipefail
BEFORE="$1"; AFTER="$2"; OUT="$3"
TOOLS="$(cd "$(dirname "$0")" && pwd)"
SE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation
PRO_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
STATES=(${CAPTURE_STATES:-dashboard dashboard@bottom dashboard-maintain dashboard-push-high
        workout workout@bottom history@bottom settings@bottom
        force-disconnected@zone force-guided-idle force-held@bottom})

build() { # tree derived-data
  while pgrep -x xcodebuild >/dev/null; do sleep 30; done
  (cd "$1/native/SendmeterNative" && xcodebuild build -project SendmeterNative.xcodeproj \
    -scheme SendmeterNative -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$2" CODE_SIGNING_ALLOWED=NO >/dev/null)
  echo "$2/Build/Products/Debug-iphonesimulator/Sendmeter.app"
}

for VERSION in ${VERSIONS:-before after}; do
  TREE="$BEFORE"; [[ "$VERSION" == after ]] && TREE="$AFTER"
  APP=$(build "$TREE" "$TMPDIR/l1032-dd-cap-$VERSION")
  for DEV in ${DEVICES:-se 17pro}; do
    TYPE="$SE_TYPE"; [[ "$DEV" == 17pro ]] && TYPE="$PRO_TYPE"
    hermes-sim-task --device-type "$TYPE" -c \
      "bash '$TOOLS/capture-phone.sh' '$APP' \"\$SIMULATOR_UDID\" '$OUT/$VERSION/$DEV' '$VERSION' ${STATES[*]}"
  done
  rm -rf "$TMPDIR/l1032-dd-cap-$VERSION"
done
