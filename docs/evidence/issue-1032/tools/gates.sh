#!/usr/bin/env bash
# #1032 gates at the lane head (from #1031's gates.sh), one named log each,
# raw exits in logs/gates-summary.txt. Run from the repo root.
#
# `just core` gets a 25-minute watchdog (brief: GuidedForceFullscreen-
# PresentationTests can hang it on staging). Xcode gates wait for any other
# xcodebuild first (one host-wide); `test` runs on a hermes-sim-task
# temporary simulator (the SE runs pass --device-type explicitly).
set -uo pipefail
L=docs/evidence/issue-1032/logs
DD="${DD:-$TMPDIR/l1032-dd}"
BASE=d00540474d1957dce48adfaa53c8bf69c0c357c9
SE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation
S="$(pwd)/$L/gates-summary.txt"
: > "$S"
note() { echo "$1" | tee -a "$S"; }
note "head=$(git rev-parse --short HEAD) date=$(date -u +%FT%TZ) df=$(df -h /System/Volumes/Data | awk 'NR==2{print $4}')"
wait_xcode() { while pgrep -x xcodebuild >/dev/null; do sleep 60; done; }
restore() { git checkout -- native/SendmeterNative/Package.resolved 2>/dev/null; }

( just core > "$L/gate-core.log" 2>&1; echo $? > "$L/.core-exit" ) & P=$!
for _ in $(seq 1 150); do sleep 10; kill -0 $P 2>/dev/null || break; done
if kill -0 $P 2>/dev/null; then
  echo "WATCHDOG: just core still running after 1500 s, killed" >> "$L/gate-core.log"
  pkill -f "impl-1032/native/SendmeterNative/.build/.*xctest"; wait $P; note "just core exit=WATCHDOG-KILLED"
else
  wait $P; note "just core exit=$(cat "$L/.core-exit")"
fi
rm -f "$L/.core-exit"; restore

just watch-core > "$L/gate-watch-core.log" 2>&1; note "just watch-core exit=$?"; restore
just health-core > "$L/gate-health-core.log" 2>&1; note "just health-core exit=$?"; restore
just slop > "$L/gate-slop.log" 2>&1; note "just slop exit=$?"
just check-static > "$L/gate-check-static.log" 2>&1; note "just check-static exit=$? (base red: ManualForceFullscreen.swift)"
just gen > "$L/gate-gen.log" 2>&1; note "just gen exit=$?"; restore
just check-watch-project > "$L/gate-check-watch-project.log" 2>&1; note "just check-watch-project exit=$?"
git diff --check origin/staging..HEAD > "$L/gate-diff-check.log" 2>&1; note "git diff --check origin/staging..HEAD exit=$? (origin/staging=$(git rev-parse --short origin/staging))"
git diff --check $BASE..HEAD > "$L/gate-diff-check-base.log" 2>&1; note "git diff --check ${BASE:0:7}..HEAD exit=$?"
git diff origin/staging HEAD -- '*Mascot*' > "$L/mascot-identity.log" 2>&1
note "git diff origin/staging HEAD -- '*Mascot*' exit=$? bytes=$(wc -c < "$L/mascot-identity.log" | tr -d ' ')"

cd native/SendmeterNative
wait_xcode
xcodebuild build -project SendmeterNative.xcodeproj -scheme SendmeterNative -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -derivedDataPath "$DD" \
  > "../../$L/gate-build-ios-unsigned.log" 2>&1
note "xcodebuild build (unsigned, generic iOS Simulator) exit=$?"
wait_xcode
xcodebuild test -project SendmeterNative.xcodeproj -scheme SendmeterNative \
  -destination 'platform=iOS Simulator,name=any' -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
  -only-testing:SendmeterNativeTests > "../../$L/gate-app-suite.log" 2>&1
note "xcodebuild test -only-testing:SendmeterNativeTests exit=$?"
wait_xcode
hermes-sim-task --device-type "$SE_TYPE" --xcodebuild -- test -project SendmeterNative.xcodeproj \
  -scheme SendmeterNative -destination 'platform=iOS Simulator,name=any' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO -only-testing:SendmeterNativeUITests/MenuActivationUITests \
  -only-testing:SendmeterNativeUITests/ManualWorkoutEndRefusalUITests \
  -only-testing:SendmeterNativeUITests/TabBarClearanceUITests > "../../$L/gate-ui-smoke-clearance-se.log" 2>&1
note "UI smoke (MenuActivation + ManualWorkoutEndRefusal) + TabBarClearanceUITests (all tabs) on iPhone SE (3rd gen) exit=$?"
cd ../..; restore
note "done"
