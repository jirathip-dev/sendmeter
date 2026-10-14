#!/usr/bin/env bash
# #1031 before/after simulator captures (17 Pro + SE, dark + light).
#
# The harness is LOCAL ONLY (apply-harness.py adds slice 1's DEBUG
# `--design-1028 <state>` fixture plus the #1031 states); it is applied to
# throwaway worktrees, never to the lane branch:
#   before = 2a13b04 (impl-1030 head, the stack base)
#   after  = the lane head under test
#
# Usage (repo root): capture-all.sh <before-tree> <after-tree> <capture-root>
#   Each tree: a checkout with apply-harness.py applied and `just gen` run.
# Writes <capture-root>/{before,after}/{17pro,se}/<label>-<state>-<scheme>.png
# One xcodebuild at a time host-wide: waits for any other xcodebuild first.
set -euo pipefail
BEFORE="$1"; AFTER="$2"; OUT="$3"
TOOLS="$(cd "$(dirname "$0")" && pwd)"
PHONE="$(cd "$TOOLS/../../issue-1030/tools" && pwd)/capture-phone.sh"
PRO=EAF1D958-7274-43E0-94F1-8CC8E0285B93
SE=EBB29F51-CA98-438D-8823-F487F60BE5BE
STATES=(${CAPTURE_STATES:-force-disconnected force-guided-idle force-guided-armed force-guided-armed@bottom
        force-guided-recording force-recording force-handsfree-armed force-interrupted force-held
        force-held@progressor})

build() { # tree derived-data
  while pgrep -x xcodebuild >/dev/null; do sleep 30; done
  (cd "$1/native/SendmeterNative" && xcodebuild build -project SendmeterNative.xcodeproj \
    -scheme SendmeterNative -configuration Debug -destination "id=$SE" -derivedDataPath "$2" \
    CODE_SIGNING_ALLOWED=NO >/dev/null)
  echo "$2/Build/Products/Debug-iphonesimulator/Sendmeter.app"
}

# VERSIONS="after" re-captures one side only (e.g. after a failed build).
for VERSION in ${VERSIONS:-before after}; do
  TREE="$BEFORE"; [[ "$VERSION" == after ]] && TREE="$AFTER"
  APP=$(build "$TREE" "$TMPDIR/l1031-dd-cap-$VERSION")
  bash "$PHONE" "$APP" "$PRO" "$OUT/$VERSION/17pro" "$VERSION" "${STATES[@]}"
  bash "$PHONE" "$APP" "$SE" "$OUT/$VERSION/se" "$VERSION" "${STATES[@]}"
  # The capture build is ~2 GB; drop it once its captures are taken.
  rm -rf "$TMPDIR/l1031-dd-cap-$VERSION"
done
