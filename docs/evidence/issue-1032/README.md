# #1032: Dashboard single verdict, sparse trend, copy cleanup, every-tab clearance (rollout #1028 slice 3/3)

Branch `impl-1032`, cut from `origin/staging` @ `d005404` (slices 1 #1030 and 2 #1031 already merged).
This is a port of the approved design round (`fc1d8ada`, `design-output/1028/`) onto current staging, with no merge or
cherry-pick of the design branch.

Refs #1032, #1022, #1023, #1024.

## What shipped

| AC | Change | Evidence |
|---|---|---|
| **#1022**: one verdict. A table gives copy for every readiness × load cell. "Recover" never sits next to an unqualified "Under-training", and recovery advice appears once. | New `Core/DashboardVerdict.swift`, ported from `fc1d8ada` with no changes: 3 readiness bands × 4 load bands give a headline plus a load line that is always qualified. `TodayDecisionCard` renders it. With no readiness, only the ratio is shown, never a bare status word. The block card's `.considerRecovery` line now points at Today's decision ("Readiness low — today's decision comes first") instead of repeating the advice. | `DashboardVerdictTests`: `testEveryCellIsEnumeratedWithItsCopy` (all **12** cells, exact headline and load line; `allCases` loops fail if a new band appears without copy), `testEveryCellHasCopy`, `testNeverRecoverNextToUnqualifiedUnderTraining`, `testRecoveryAdviceAppearsOnce`, `testOwnersState`, `testBands`, `testDashboardRendersTheVerdictAndTheSparseTrendOpensTheExistingSheet`. Sheets `*-dashboard`, `*-dashboard-maintain`, `*-dashboard-push-high`. |
| **#1023**: sparse trend. The copy is exact, and "Check recovery inputs" opens the EXISTING sheet. | `ReadinessTrendCard`: below `ReadinessTrendDensity.minimumScoredDays` (5) scored days in the 14-day window, the chart is replaced by "N readiness scores in the last 14 days — the trend needs a few more." plus a "Check recovery inputs" button. The card takes an `onOpenRecoveryInputs` closure. The Dashboard passes `{ showRecovery = true }`, which drives the one existing `.sheet(isPresented: $showRecovery) { RecoveryInputsSheet() }`. No sheet was added. | `testSparseTrend` (exact copy at 0, 1, 2 and 4; dense at 5 and above); the wiring test asserts one `.sheet(isPresented: $showRecovery)` and no `.sheet(`/`.fullScreenCover(` in the trend card. Sheet `*-dashboard` (2 scored days). |
| **#1024 + P10**: no implementation prose in user-facing copy | "Identity dot · tap to arm" caption removed (`ForceRecordingContextCard`; minimal edit, its `Spacer` kept). `ZoneFocusCard`: "Last 4 weeks · this exercise". `WorkoutView`: "Tap once per attempt, then finish." (was "…written atomically…"). Also, per the approved #1024 table in `fc1d8ada`: in `ForceView`, "N saved" replaces "queued" / "durably queued"; "Pull finished — save it to keep it"; "This pull hasn't been saved yet. Once discarded, it can't be recovered."; "From your Apple Watch · updated …"; "Saved pulls appear here."; and in `WorkoutView`, "Live from your Apple Watch". `ForceMotionWiringTests:233` was flipped on purpose to `XCTAssertFalse(card.contains("Identity dot"))`. | `testNoImplementationProseInUserFacingCopy` (a grep gate over user-facing literals); `logs/static-checks.log` (the three brief strings: every remaining hit is a `///` comment, and the non-comment grep exits 1). Sheets `*-workout`, `*-force-disconnected-zone`, `*-force-guided-idle`. |
| **F5**: every tab's last row sits fully above the tab bar on iPhone SE | `DesignSystem.sendmeterTabBarEdge(_:)`: an opaque bottom edge (0-pt `safeAreaInset`, background runs under the tab bar) plus a 14 pt fade. Applied to Dashboard (`canvas`), Workout, History and Settings (`systemGroupedBackground`). `TabBarClearanceUITests` gains one SE case per tab. The Force case is unchanged. | `logs/clearance-se-8.log` (exit 0, 5/5): Dashboard 528.0 < 584; Workout 551.5 < 584; History 560.0 < 584; Settings 564.0 < 584; Force 411.0 < 449. RED probes below. Sheets `*-dashboard-bottom`, `*-workout-bottom`, `*-history-bottom`, `*-settings-bottom`. |
| Slice-2 behaviour unchanged | One change in `ForceView`'s scroll stack, which is a **regression fix this slice exposed** (see "Force hang" below). Bar, auto-reconnect, P9, P11 and #1004 code are untouched. | Force clearance case green (`clearance-se-8`); `gate-app-suite.log`; sheet `*-force-held-bottom` (Unsaved pull · Save pull) |
| Mascots byte-identical; no imageset; no DEBUG switch; no `DesignFixture1028`; no AppModel change | Nothing under `*Mascot*` or `*.imageset`, and `AppModel.swift` is not in the diff. | `logs/static-checks.log`, `logs/mascot-identity.log` (0 bytes) |
| Palette gate green | No colour literal added; the new code uses `SendmeterStyle.textSecondary`/`primaryText`/`canvas` tokens and the system grouped background (as the base did). | `SendmeterPaletteGateTests` in `logs/gate-core.log.gz` |
| `HeroMetricWiringTests` | One assertion updated, because the design changes the call site: `ReadinessTrendCard()` → `ReadinessTrendCard(onOpenRecoveryInputs: { showRecovery = true })` (#1023 hand-off). `RoutineRunnerVisualWiringTests` needed no change. | `logs/focused-core-1.log` |

## Ported vs NOT ported from `fc1d8ada`

Ported (rebased by hand onto staging):

- `Sources/Core/DashboardVerdict.swift`, `Tests/SendmeterCoreTests/DashboardVerdictTests.swift`. The tests add the per-cell
  enumeration, the wiring test and `"Identity dot"` in the prose gate.
- `Features/Dashboard/DashboardView.swift`, `ReadinessTrendCard.swift`
- `Features/Force/ZoneFocusCard.swift`, `ForceRecordingContextCard.swift` (caption only), and the `ForceView.swift` copy hunks
- `Features/Workout/WorkoutView.swift`, `History/HistoryView.swift`, `Settings/SettingsView.swift` (1–6 lines each)
- `App/DesignSystem.swift`: `sendmeterTabBarEdge` only
- `Tests/SendmeterNativeUITests/TabBarClearanceUITests.swift`: the design's every-tab idea, added as four NEW cases beside
  slice 2's Force case, which is unchanged. The design's single loop test was not taken.

Deliberately NOT ported (design-round scaffolding, or already on staging from slices 1–2):

- `App/DesignFixture1028.swift`, plus the fixture hooks in `AppModel.swift`, `SendmeterNativeApp.swift` and
  `Platform/TindeqBluetooth.swift`
- `designRoundMascot(_:)` / `--design-1028-mascots` and every candidate `*1028` mascot imageset. `design-output/1028/mascots/**`.
- `App/ChartTheme.swift`: the design-branch copy predates slice 1's palette tokens (it carries literal hexes), and staging
  already resolves these from `SendmeterPalette`.
- `ChalkTexture.seed = 1028`: staging's `0x404` is the same number.
- The slice-2 files the design also touches (`ForceBarPolicy`, `ForceAutoReconnect` and their tests, the
  `SendmeterNativeTests/*` app tests, `EmptyStateWiringTests`, `ForceEmptyStateArtworkWiringTests`,
  `TabMascotWiringTests`, `SendmeterPaletteGateTests`): these are slice 1/2 scope, already merged.

## Force hang (found by this slice's clearance run; fixed in `eb39d9f`)

With the shorter #1024 empty copy ("Saved pulls appear here."), the slice-2 Force clearance case hung on SE twice. After
the first drag the app never went idle, and XCTest reported "App animations complete notification not received".

- `logs/clearance-se-2-force.log`: the hang.
- `logs/clearance-se-3-force-hyp.log`, exit 0: the same head with ONLY that string reverted. This is one variable.
- `logs/clearance-se-4-force-sample.sample.txt`: `sample` of the app shows the main thread at 99 % CPU in SwiftUI layout.
  The stack is `_UIHostingView.layoutSubviews` → `ScrollViewLayoutComputer` → `InsetViewLayout` (the bottom
  `safeAreaInset` that holds slice 2's bar) → `LazyVStackLayout` / `LazyLayoutViewCache.updateItemPhases`, re-measuring
  without end.

Fix: Force's scroll stack is a plain `VStack` instead of a `LazyVStack`. The tab holds about ten cards, so lazy loading
saved nothing. After the fix the Force case is green in every later run (`clearance-se-5…8`). The only pixel effect is a
sub-pixel antialiasing difference on 17 Pro (see the table: 1.85 % of pixels > 16; 0 pt shift).

## Before / after vs the approved sheets

`tools/apply-harness.py <tree>` applies #1031's DEBUG `--design-1028 <state>` harness (`issue-1031/tools/apply-harness.py`)
to a **scratch** worktree, then adds the #1032 states:

- `dashboard-maintain`: readiness 55, ratio 0.85
- `dashboard-push-high`: readiness 85, ratio 1.38
- both dense, 14 scored days
- a `@zone` scroll to the Training balance card

Nothing from the harness is in the lane's sources.

The trees:

- **before**: `origin/staging` `d005404` + harness
- **after**: `eb39d9f` + harness. `eb39d9f` holds every source change; later commits add evidence only.

`tools/capture-all.sh <before> <after> <root>` builds each tree once and captures on a temporary simulator owned by
`hermes-sim-task` (iPhone SE 3rd gen and iPhone 17 Pro, iOS 26.5, dark + light; `tools/capture-phone.sh`). Then run
`tools/stage-screens.sh` (`issue-1031/tools/check-shots.py`: "88 captures show the app") and `tools/sheets.py <approved>`.
`tools/compare-approved.py` (`logs/compare-approved.log`) diffs each after-capture against its approved twin.

Each sheet shows **before · after · approved #1028**, dark then light. A state the approved round did not capture has no
third column.

| State (AC) | iPhone 17 Pro | iPhone SE | Visible difference after vs approved |
|---|---|---|---|
| Dashboard: readiness 38, ratio 0.66, 2 scored days. #1022 cell recover/under (the approved "Recover today — easy movement only." example) and #1023 sparse | [sheet](sheets/17pro-dashboard.png) | [sheet](sheets/se-dashboard.png) | 0.07 % of pixels: the "Last synced" timestamp and the chalk speckle under the headline. The copy is identical: "Recover today — easy movement only." · "Load ratio 0.66 · light week, expected at low readiness" · "2 readiness scores in the last 14 days — the trend needs a few more." · "Check recovery inputs". |
| Dashboard: readiness 55, ratio 0.85. #1022 maintain/optimal, dense trend kept | [sheet](sheets/17pro-dashboard-maintain.png) | [sheet](sheets/se-dashboard-maintain.png) | No approved twin. After: "Maintain — train, but keep one rep in reserve." · "Load ratio 0.85 · on track". Before: the same headline beside an unqualified "Load ratio 0.85 · Optimal". |
| Dashboard: readiness 85, ratio 1.38. #1022 push/high, dense trend kept | [sheet](sheets/17pro-dashboard-push-high.png) | [sheet](sheets/se-dashboard-push-high.png) | No approved twin. After: "Ready, but hold load — keep volume where it is." · "Load ratio 1.38 · high, don't add volume". Before: "Ready to train — use the planned block intensity." beside "Load ratio 1.38 · Caution", which contradicts it. |
| Dashboard scrolled to end (F5) | [sheet](sheets/17pro-dashboard-bottom.png) | [sheet](sheets/se-dashboard-bottom.png) | 0.6–0.9 %: the session dates only (x 122–248 pt). The approved round captured on another day. |
| Workout: manual-workout copy (#1024) | [sheet](sheets/17pro-workout.png) | [sheet](sheets/se-workout.png) | No approved top-of-tab twin. The approved `workout-bottom` frame shows the same card and copy: "Tap once per attempt, then finish." |
| Workout scrolled to end (F5) | [sheet](sheets/17pro-workout-bottom.png) | [sheet](sheets/se-workout-bottom.png) | None: 0.00 % on 17 Pro; SE 0.00 % (a 1 pt home-indicator speck). |
| History scrolled to end (F5) | [sheet](sheets/17pro-history-bottom.png) | [sheet](sheets/se-history-bottom.png) | 0.02–0.04 %: an 11 pt wide column at x 122–135, which is spinner / relative-time text. |
| Settings scrolled to end (F5) | [sheet](sheets/17pro-settings-bottom.png) | [sheet](sheets/se-settings-bottom.png) | None: 0.00 %. |
| Force: Training balance subtitle (#1024) | [sheet](sheets/17pro-force-disconnected-zone.png) | [sheet](sheets/se-force-disconnected-zone.png) | No approved twin (the approved round did not scroll here). After: "Last 4 weeks · this exercise"; before: "… this exercise only · sets, not sessions". |
| Force: context card (P10) | [sheet](sheets/17pro-force-guided-idle.png) | [sheet](sheets/se-force-guided-idle.png) | The "Identity dot · tap to arm" caption is gone; that is the only layout change (0 pt vertical shift, measured). The approved capture predates the P10 decision, so it still shows the caption. SE: 0.23 % (the caption's box only). 17 Pro: 1.85 %, the caption plus sub-pixel antialiasing on the card text from the `LazyVStack` → `VStack` fix. Before vs approved is 0.00 % on both phones. |
| Force: scrolled to end with a held pull (slice-2 bar + #1004 unchanged) | [sheet](sheets/17pro-force-held-bottom.png) | [sheet](sheets/se-force-held-bottom.png) | No approved twin. The bar still reads "Unsaved pull" · Save pull, and the last recording ends above the bar on both phones. |

**F5 is not visible in these captures. Read the UI test.** The harness's `@bottom` frames look the same before and after:
in the DEBUG fixture the base's last row already lands above the bar at the default text size. The F5 proof is
therefore the UI test, not the sheet. `TabBarClearanceUITests` runs each tab at the largest accessibility text size, so
every tab overflows the SE screen. It drags until the last row stops moving, and it fails a vacuous end. The four RED
probes below re-create content running under the tab bar on one tab each, and each case catches it.

## Gate proofs (RED probes)

`tools/red-probes.sh <probe> logs`. Core probes are `swift test` on one test; UI probes are `xcodebuild test` on a fresh
`hermes-sim-task` iPhone SE (3rd gen), one case each. The GREEN for the UI probes is the unmutated all-tabs run
`logs/clearance-se-8.log` (exit 0). Raw lines are in `logs/red-probes-core.txt` and `logs/red-probes-ui.txt`.

| Probe | Planted defect | Focused test | RED exit (asserting line) | GREEN |
|---|---|---|---|---|
| `verdict-cell` | the recover/no-load cell says the old "Recover — keep intensity low…" | `DashboardVerdictTests/testEveryCellIsEnumeratedWithItsCopy` | **1** (`:50`) | 0 |
| `verdict-wiring` | `ReadinessTrendCard()` without the recovery hand-off | `…/testDashboardRendersTheVerdictAndTheSparseTrendOpensTheExistingSheet` | **1** (`:128`) | 0 |
| `copy-identity` | re-add `Text("Identity dot · tap to arm")` | `…/testNoImplementationProseInUserFacingCopy` | **1** (`:172`) | 0 |
| `copy-sets` | re-add "… this exercise only · sets, not sessions" | `…/testNoImplementationProseInUserFacingCopy` | **1** (`:172`) | 0 |
| `copy-atomic` | re-add "…written atomically." | `…/testNoImplementationProseInUserFacingCopy` | **1** (`:172`) | 0 |
| `ui-dashboard` | Dashboard scroller `.ignoresSafeArea(.container, edges: .bottom)` (content runs under the tab bar) | `TabBarClearanceUITests/testDashboardLastRowIsFullyVisibleAboveTheTabBar` | **65** (`:161`; last row 611.0, under the bar at 584) | 0 (`clearance-se-8`) |
| `ui-workout` | the same, Workout | `…/testWorkoutLastRowIsFullyVisibleAboveTheTabBar` | **65** (`:161`; 634.5 > 584) | 0 |
| `ui-history` | the same, History | `…/testHistoryLastRowIsFullyVisibleAboveTheTabBar` | **65** (`:161`; 643.0 > 584) | 0 |
| `ui-settings` | the same, Settings | `…/testSettingsLastRowIsFullyVisibleAboveTheTabBar` | **65** (`:161`; 647.0 > 584) | 0 |

Why the UI probes plant `ignoresSafeArea` rather than delete `.sendmeterTabBarEdge`: the edge is geometry-neutral. It is a
0-pt inset that paints the opaque band and the fade, so the scroll content already ends at the tab bar's safe-area line
without it. `logs/clearance-se-noedge.log` records the four cases with all four edges deleted (see "Disclosed" below).

## Gates (raw exits)

See `logs/gates-summary.txt` (`tools/gates.sh`, at head `eb39d9f`).

## Disclosed

- **Clearance-test hardening rounds.** Runs 1–7 (`logs/clearance-se-1…7`) show the new cases being tightened, each for a
  measured reason:
  - Runs 1 and 2: the Force hang, above.
  - Run 5: at the default size, a signed-out tab could pass vacuously (e.g. a splash image frame); the cases now run at
    the largest text size.
  - Run 6: ten drags did not reach the end of a very tall Dashboard; the cases now drag until the last row stops moving.
  - Run 7: a List's `AdditionalDimmingOverlay` image (it ends about 140 pt below the SE screen) counted as a "row"; only
    rows wholly on screen inside the scroller count now.
  - Run 8 is the final GREEN.
- **The F5 sheets show no visual delta** in this harness (see the bold note under the table).
- `GuidedForceFullscreenPresentationTests` can hang `just core` (a known staging flake). `tools/gates.sh` has a 25-minute
  watchdog; see the summary.
- `just check-static` is red at base (`ManualForceFullscreen.swift`). Recorded, not fixed.

## Tools

- `tools/apply-harness.py`: #1031's harness plus the #1032 states. Scratch trees only.
- `tools/capture-all.sh`, `tools/capture-phone.sh`: before/after captures on `hermes-sim-task` temporary simulators.
- `tools/stage-screens.sh`, `tools/sheets.py`, `tools/compare-approved.py`: stage, sheet and diff against approved.
- `tools/clearance-se.sh`: `TabBarClearanceUITests` on a temporary iPhone SE (3rd gen).
- `tools/red-probes.sh`, `tools/ui-chain.sh`: RED probes (core and UI).
- `tools/sample-hang.sh`: the Force hang diagnosis (`sample` of the app during the idle-wait).
- `tools/gates.sh`: the final gate run.
