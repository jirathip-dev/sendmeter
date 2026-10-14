#!/usr/bin/env bash
# #1032 SE TabBarClearanceUITests run (all tabs) on a hermes-sim-task temporary
# iPhone SE (3rd gen). One xcodebuild host-wide: waits for any other first.
# Usage (repo root): bash docs/evidence/issue-1032/tools/clearance-se.sh <log> [only-testing...]
set -uo pipefail
LOG="$1"; shift
ONLY=("$@"); [[ ${#ONLY[@]} -eq 0 ]] && ONLY=(SendmeterNativeUITests/TabBarClearanceUITests)
DD="${DD:-$TMPDIR/l1032-dd}"
SE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation
while pgrep -x xcodebuild >/dev/null; do sleep 60; done
ARGS=()
for t in "${ONLY[@]}"; do ARGS+=("-only-testing:$t"); done
cd native/SendmeterNative
hermes-sim-task --device-type "$SE_TYPE" --xcodebuild -- test -project SendmeterNative.xcodeproj \
  -scheme SendmeterNative -destination 'platform=iOS Simulator,name=any' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO "${ARGS[@]}" > "$LOG" 2>&1
rc=$?
git checkout -- Package.resolved 2>/dev/null
exit $rc
