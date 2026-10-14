#!/usr/bin/env bash
# #1032 RED probes: each mutation reverts ONE slice-3 rule and must turn its
# focused test RED (non-zero exit); the unmutated run is GREEN.
#
# Usage (repo root): bash docs/evidence/issue-1032/tools/red-probes.sh <probe> <log-dir>
#   core probes (swift test): verdict-cell verdict-wiring copy-identity copy-sets copy-atomic
#   UI probes (xcodebuild on a temporary iPhone SE via hermes-sim-task; DD=<derived data>):
#     ui-dashboard ui-workout ui-history ui-settings
# Each UI probe re-creates the F5 defect on ONE tab, content running under the
# tab bar, by making that tab's scroller ignore the bottom safe area (right
# where its `.sendmeterTabBarEdge(...)` sits), and runs only that tab's
# TabBarClearanceUITests case. (`sendmeterTabBarEdge` itself is geometry-
# neutral: a 0-pt inset that paints the opaque band, so deleting it cannot
# move a row.) One xcodebuild at a time host-wide.
set -uo pipefail

PROBE="$1"
LOGS="$2"
ROOT="$(git rev-parse --show-toplevel)"
PKG="$ROOT/native/SendmeterNative"
DD="${DD:-$TMPDIR/l1032-dd}"
DEVICE_TYPE="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation}"
mkdir -p "$LOGS"

mutate() { # file old new
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
assert text.count(old) == 1, f"mutation anchor not unique in {path}: {old!r}"
open(path, "w").write(text.replace(old, new))
PY
}

restore() { git -C "$ROOT" checkout -- "$1"; git -C "$ROOT" checkout -- native/SendmeterNative/Package.resolved 2>/dev/null || true; }

core_probe() { # file old new filter
  mutate "$PKG/$1" "$2" "$3" || exit 2
  swift test --package-path "$PKG" --filter "$4" > "$LOGS/red-$PROBE.log" 2>&1
  local red=$?
  restore "$PKG/$1"
  swift test --package-path "$PKG" --filter "$4" > "$LOGS/green-$PROBE.log" 2>&1
  local green=$?
  restore "$PKG/$1"
  echo "probe=$PROBE red_exit=$red green_exit=$green"
}

ui_probe() { # file anchor test-name
  mutate "$PKG/$1" "$2" "$2            .ignoresSafeArea(.container, edges: .bottom)
" || exit 2
  while pgrep -x xcodebuild >/dev/null; do sleep 60; done
  (cd "$PKG" && hermes-sim-task --device-type "$DEVICE_TYPE" --xcodebuild -- test \
    -project SendmeterNative.xcodeproj -scheme SendmeterNative \
    -destination "platform=iOS Simulator,name=any" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
    -only-testing:"SendmeterNativeUITests/TabBarClearanceUITests/$3") > "$LOGS/red-$PROBE.log" 2>&1
  local red=$?
  restore "$PKG/$1"
  echo "probe=$PROBE red_exit=$red (GREEN: the unmutated all-tabs clearance run)"
}

EDGE_GROUPED='            // #1028 F5: opaque edge under the tab bar.
            .sendmeterTabBarEdge(Color(uiColor: .systemGroupedBackground))
'
case "$PROBE" in
  verdict-cell)
    core_probe Sources/Core/DashboardVerdict.swift \
      'return Copy(headline: "Recover today — easy movement only.", loadLine: nil)' \
      'return Copy(headline: "Recover — keep intensity low and reduce volume.", loadLine: nil)' \
      DashboardVerdictTests/testEveryCellIsEnumeratedWithItsCopy ;;
  verdict-wiring)
    core_probe Sources/Features/Dashboard/DashboardView.swift \
      'ReadinessTrendCard(onOpenRecoveryInputs: { showRecovery = true })' 'ReadinessTrendCard()' \
      DashboardVerdictTests/testDashboardRendersTheVerdictAndTheSparseTrendOpensTheExistingSheet ;;
  copy-identity)
    core_probe Sources/Features/Force/ForceRecordingContextCard.swift \
      '                Spacer(minLength: 8)
            }' '                Spacer(minLength: 8)
                Text("Identity dot · tap to arm")
            }' \
      DashboardVerdictTests/testNoImplementationProseInUserFacingCopy ;;
  copy-sets)
    core_probe Sources/Features/Force/ZoneFocusCard.swift \
      'Text("Last 4 weeks · this exercise")' 'Text("Last 4 weeks · this exercise only · sets, not sessions")' \
      DashboardVerdictTests/testNoImplementationProseInUserFacingCopy ;;
  copy-atomic)
    core_probe Sources/Features/Workout/WorkoutView.swift \
      'Text("Tap once per attempt, then finish.")' 'Text("The complete workout is written atomically.")' \
      DashboardVerdictTests/testNoImplementationProseInUserFacingCopy ;;
  ui-dashboard)
    ui_probe Sources/Features/Dashboard/DashboardView.swift '            .sendmeterTabBarEdge()
' testDashboardLastRowIsFullyVisibleAboveTheTabBar ;;
  ui-workout)
    ui_probe Sources/Features/Workout/WorkoutView.swift "$EDGE_GROUPED" testWorkoutLastRowIsFullyVisibleAboveTheTabBar ;;
  ui-history)
    ui_probe Sources/Features/History/HistoryView.swift "$EDGE_GROUPED" testHistoryLastRowIsFullyVisibleAboveTheTabBar ;;
  ui-settings)
    ui_probe Sources/Features/Settings/SettingsView.swift "$EDGE_GROUPED" testSettingsLastRowIsFullyVisibleAboveTheTabBar ;;
  *) echo "unknown probe: $PROBE" >&2; exit 2 ;;
esac
