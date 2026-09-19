#!/usr/bin/env bash
# #917 probe runner (round 2). Snapshots the two touched source files, applies
# ONE guard mutation at a time, runs the targeted app tests, captures the RED
# log + the exact diff, restores the snapshot and verifies the blob hash.
#
# Usage: bash run-probes2.sh <green|A|B|C|D> [more...]
set -uo pipefail
WT=/Users/jirathip/.herdr/worktrees/sendmeter/impl-917
APP="$WT/native/SendmeterNative/Sources/App/AppModel.swift"
CORE="$WT/native/SendmeterNative/Sources/Core/DirectWriteReplay.swift"
SNAP=/tmp/917logs/green
EV="$WT/docs/evidence/issue-917"
SIM=0E127B96-BF94-48E0-A61B-0C018D9D79C7
mkdir -p "$SNAP"

snapshot() {
  cp "$APP" "$SNAP/AppModel.swift"
  cp "$CORE" "$SNAP/DirectWriteReplay.swift"
  git -C "$WT" hash-object "$SNAP/AppModel.swift" | sed 's/^/AppModel green blob: /'
  git -C "$WT" hash-object "$SNAP/DirectWriteReplay.swift" | sed 's/^/DirectWriteReplay green blob: /'
}

restore() {
  cp "$SNAP/AppModel.swift" "$APP"
  cp "$SNAP/DirectWriteReplay.swift" "$CORE"
}

verify() {
  local a c
  a=$(git -C "$WT" hash-object "$APP")
  c=$(git -C "$WT" hash-object "$CORE")
  [ "$a" = "$(git -C "$WT" hash-object "$SNAP/AppModel.swift")" ] && echo "AppModel restored ($a)" || echo "APP MODEL MISMATCH: $a"
  [ "$c" = "$(git -C "$WT" hash-object "$SNAP/DirectWriteReplay.swift")" ] && echo "DirectWriteReplay restored ($c)" || echo "CORE MISMATCH: $c"
}

apply_probe() {
  python3 - "$APP" "$CORE" "$1" <<'PY'
import sys
app, core, which = sys.argv[1], sys.argv[2], sys.argv[3]

def sub(text, old, new):
    assert text.count(old) == 1, ("NO MATCH", which, old[:70], text.count(old))
    return text.replace(old, new)

a = open(app).read()
c = open(core).read()

if which == "A":
    # Drop the already-applied / completeness guard.
    a = sub(a, """        if PhaseTransitionReplayPolicy.isApplied(
            intent: intent,
            serverPeriods: serverPeriods
        ) {""",
        """        if false, PhaseTransitionReplayPolicy.isApplied(
            intent: intent,
            serverPeriods: serverPeriods
        ) {""")
elif which == "B":
    # Drop the settings-completeness write.
    a = sub(a, """            if serverSettings != intent.settings {
                try await repository.updateSettings(intent.settings, userID: userID)
            }""",
        """            _ = serverSettings""")
elif which == "C":
    # Drop the revision comparison in the confirmation.
    a = sub(a, """            let current = try? workspace.localRevision(
                accountUserID: accountUserID,
                entityType: .phasePeriods,
                entityID: entityID
            )
            guard captured == current else {
                // A newer local transition owns this row.
                isNewest = false
                continue
            }""",
        """            let current = captured
            guard captured == current else {
                // A newer local transition owns this row.
                isNewest = false
                continue
            }""")
    a = sub(a, """            let current = try? workspace.localRevision(
                accountUserID: accountUserID,
                entityType: .phasePeriods,
                entityID: entityID
            )
            guard captured == current else {
                isNewest = false
                continue
            }""",
        """            let current = captured
            guard captured == current else {
                isNewest = false
                continue
            }""")
    a = sub(a, """        let settingsCurrent = try? workspace.localRevision(
            accountUserID: accountUserID,
            entityType: .settings,
            entityID: settingsID
        )""",
        """        let settingsCurrent = settingsCaptured""")
elif which == "D":
    # Drop the server re-anchoring: a replayed transition is always authored
    # against its own pre-state, so an already-landed create is planned again.
    c = sub(c, """        isServerAnchored(intent: intent, serverPeriods: serverPeriods)
            ? intent.previousPeriods
            : serverPeriods""",
        """        _ = serverPeriods
        return intent.previousPeriods""")
else:
    raise SystemExit("unknown probe " + which)

open(app, "w").write(a)
open(core, "w").write(c)
print("probe", which, "applied")
PY
}

TESTS_FOR() {
  case "$1" in
    A) echo "-only-testing:SendmeterNativeTests/PhaseTransitionReplayAppTests/testTerminationAfterServerSuccessBeforeLocalAcknowledgementReplaysIdempotently -only-testing:SendmeterNativeTests/PhaseTransitionReplayAppTests/testLostSettingsHalfIsCompletedFromTheServerState";;
    B) echo "-only-testing:SendmeterNativeTests/PhaseTransitionReplayAppTests/testLostSettingsHalfIsCompletedFromTheServerState";;
    C) echo "-only-testing:SendmeterNativeTests/PhaseTransitionReplayAppTests/testOlderTransitionCompletionCannotClearANewerLocalBlock";;
    D) echo "-only-testing:SendmeterNativeTests/PhaseTransitionReplayAppTests/testOlderTransitionCompletionCannotClearANewerLocalBlock";;
  esac
}

run_tests() { # $1 = log name, rest = -only-testing args
  local log="$1"; shift
  (cd "$WT" && xcrun xcodebuild test -project native/SendmeterNative/SendmeterNative.xcodeproj \
      -scheme SendmeterNative -destination "id=$SIM" \
      "$@" CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/917-DD) \
      > "/tmp/917logs/$log" 2>&1
  echo "xcodebuild exit=$? -> /tmp/917logs/$log"
  # Reclaim the result bundle: the host data volume is at 98% (reported), and
  # the stdout log is the evidence that is kept.
  rm -rf /tmp/917-DD/Logs/Test
  grep -E "Test Case '.*(passed|failed)|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)" "/tmp/917logs/$log" | tail -6
}

snapshot

for which in "$@"; do
  restore
  if [ "$which" = "green" ]; then
    run_tests "app-phase-6-green.log" "-only-testing:SendmeterNativeTests/PhaseTransitionReplayAppTests"
    continue
  fi
  apply_probe "$which" || { echo "probe $which failed to apply"; continue; }
  diff -u "$SNAP/AppModel.swift" "$APP" > "$EV/probe-$which.diff"
  diff -u "$SNAP/DirectWriteReplay.swift" "$CORE" >> "$EV/probe-$which.diff"
  echo "=== probe $which ==="
  run_tests "red-probe$which.log" $(TESTS_FOR "$which")
done

restore
verify
