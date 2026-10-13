# #1028 design round: Sendmeter climbing-native refinement (light touch)

Branch `design-1028-refine`, base `origin/staging` @ `48788ef`. Locked spec: issue #1028
(A–E) plus the owner's **locked amendment F** (2026-10-13). This is a refinement, not a redesign:
build 57's layouts, cards and information architecture are kept.

**Start here on a phone:** `sheets/17pro-overview-dark.png`, then the per-state before/after sheets below.

## What changed (spec item → where)

| Spec | Change | Code |
|---|---|---|
| **F1** | The bottom bar is the **only** device status and Connect/Reconnect. The "Recording device" row, the Progressor card's status line and pill, and its reconnect panel are gone. This supersedes D3's tappable row. | `Features/Force/ForceBottomBar.swift`, `Core/ForceBarPolicy.swift`, `ForceRecordingContextCard.swift` |
| **F2** | A **Guided \| Hands-free** switch in the bar, and the big action follows the mode. Guided: Connect → Start → Stop & save. Hands-free: Connect → Arm → (pull) → saves on release. The Hands-free toggle is off the card. The armed protocol name in the bar opens the list (D2). | `ForceBarPolicy.state(_:)`, `ForceBarPolicyTests` |
| **F3** | Disconnected or interrupted, the card shows **"Waiting for Progressor"**, with no "Live readout" chip and no "Armed now". The header reads "Selected protocol" (P3). | `ForceContextReadiness`, `ForceMotionWiringTests` |
| **F4** | **"Hold 30.3 s"** label, and a light kg scale on the trace (≤ 4 "nice" ticks, labels plus hairlines, no heavy grid). | `ForceReadoutFormat`, `ForceTraceScale` |
| **F5** | No content scrolls under the tab bar or the Force bar on any tab. There is an opaque bottom edge and a 14 pt fade (P4). A **UI test** checks the last row of all 5 tabs on an iPhone SE. It passes (for example, Force's last row ends at 410.5 pt and its bar starts at 449). With the Force bar deliberately moved into an overlay, it fails (last row at 471.75 pt, below the bar top) and the file is restored afterwards. | `DesignSystem.sendmeterTabBarEdge`, `Tests/SendmeterNativeUITests/TabBarClearanceUITests.swift` |
| **D1–D4** | Sticky bar above the tab bar. The status dot, protocol name and one action live there. One word for the state, "Disconnected", everywhere. #1004 held-pull Save/Discard is reachable from the bar ("Unsaved pull → Save pull"). | `ForceBarPolicy` |
| **B1** | **One shared palette**, Foundation-only, in `SendLogWatchCore/SendmeterPalette.swift`. The phone and Watch resolve it at the edge. The Watch uses the phone's dark ramp: the navy canvas becomes slate, and the mint "success" becomes the phone's blue. | `SendmeterPalette.swift`, `WatchDesign.swift`, `SendmeterPaletteTests` |
| **B2** | A gate test fails on any `Color(hex:)` or colour literal outside the token files (phone and Watch), and a planted literal is caught. | `SendmeterPaletteGateTests` |
| **B3** | Every text pair is AA in both themes (81 pairs, **0 exceptions**), including text on the chalk texture at its worst case. **Status pills:** build 57 painted the pill label in its raw hue, at 1.9–2.9:1 in light mode (for example, the orange "Recover" pill was 2.69:1). Labels are now the hue mixed into the primary text colour at 45%, which keeps the hue and clears AA on every surface (worst case 4.71:1). | `tokens.md` (generated), `SendmeterPalette.pillText`, `StatusPill`, `SendmeterPaletteContrastTests` |
| **A1** | A chalk texture on **two** hero surfaces only: Today's decision, and the armed protocol. It is a fixed-seed speckle in the text token, its opacity is capped by contrast, and it is hidden under Increase Contrast or Reduce Transparency. | `DesignSystem.ChalkTexture`, `SendmeterPalette.chalkOpacity` |
| **C1–C3** | The same characters and poses, lightly re-traced, plus a **carabiner** prop (P5). These are **candidate assets**: the approved masters are untouched, and the in-app swap is DEBUG-only (`--design-1028-mascots refined`). **Caveat:** at real in-app size (60–120 pt) the re-trace looks almost the same as the master, and the carabiner reads as a small clip or paperclip rather than clearly as a carabiner. See `sheets/mascot-in-app.png`. | `mascots/` |
| **#1022** | **One Dashboard verdict** from a readiness × load table, with copy for every cell. "Recover" never sits next to an unqualified "Under-training", and recovery advice appears once. | `Core/DashboardVerdict.swift`, `DashboardVerdictTests` |
| **#1023** | Sparse readiness trend (2 points): one line plus **"Check recovery inputs"**, which opens the existing recovery-inputs sheet. | `ReadinessTrendCard.swift` |
| **#1024** | No implementation prose. For example, "durably queued" became "saved", and "sets, not sessions" became "Last 4 weeks · this exercise". | `ForceView`, `WorkoutView`, `ZoneFocusCard` |

Extras the owner can accept or reject one by one: **`proposals.md`** (P1–P11).

## Run the prototype (real SwiftUI, real `MainTabView`, seeded data)

The app's DEBUG build has a design harness, `Sources/App/DesignFixture1028.swift`. One launch argument renders the
real screens over deterministic data, with no sign-in and no Progressor:

```sh
cd native/SendmeterNative && xcodegen generate
xcodebuild -project SendmeterNative.xcodeproj -scheme SendmeterNative -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/dd1028 \
  CODE_SIGNING_ALLOWED=NO build
APP=/tmp/dd1028/Build/Products/Debug-iphonesimulator/Sendmeter.app
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.jirathip.sendlog.native --design-1028 force-guided-armed
```

States (`--design-1028 <state>`): `force-disconnected`, `force-guided-idle` (connected, nothing armed),
`force-guided-armed`, `force-recording`, `force-handsfree-armed` (armed, waiting for pull), `force-interrupted` (F3),
`dashboard` (readiness 38, load 0.66, 2 trend points), and `workout` / `history` / `settings` (F5).
Add `--design-1028-scroll bottom` to scroll the tab to its end, `--design-1028-scroll progressor` for Force's
Progressor card, or `--design-1028-mascots refined` for the candidate mascots. The app is fully interactive: switch
mode, open the protocol list, change tab.

Watch: build the `SendLogWatch Watch App` scheme for a Watch simulator, then run
`tools/capture-watch.sh <app> <udid> <out> <label> status forceConnected@force forceLive@force`.

## Reproduce every artifact

| Artifact | Command (repo root) |
|---|---|
| Phone screenshots | `design-output/1028/tools/capture-phone.sh <app> <udid> design-output/1028/screens/after/<device> after <states…>` (status bar pinned to 9:41; app proven frontmost before the shutter) |
| Watch screenshots | `design-output/1028/tools/capture-watch.sh …` (see above) |
| Repo screenshots (50 %, stripped, byte-stable) | `design-output/1028/tools/stage-screens.sh <capture-root>` |
| Comparison sheets | `python3 design-output/1028/tools/sheets.py` |
| Token table + AA check | `design-output/1028/tools/tokens.sh` (rewrite) / `--check` (fails if stale or any pair < AA) |
| Mascots + verifier | `python3 design-output/1028/mascots/generate.py && python3 design-output/1028/mascots/verify.py`. The verifier gates master byte-pins, determinism, figure IoU, hole count, **local drift (no 8×8-unit window more than 6 % different)** and prop clearance. The local-drift gate was added after a blur-22 re-trace erased the Workout bear's nose and smile while the figure-wide IoU still read 0.97. |
| Capture sanity | `python3 design-output/1028/tools/check-shots.py <png>…` rejects splash and home-screen frames (stage-screens.sh runs it first, fail-closed) |
| Unit and gate tests | `cd native/SendmeterNative && swift test` · `cd ios/App/SendLogWatchCore && swift test` |
| F5 UI test (SE) | `xcodebuild test -scheme SendmeterNative -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -only-testing:SendmeterNativeUITests/TabBarClearanceUITests` |
| F5 gate GREEN + RED proof | `design-output/1028/tools/f5-gate.sh` runs the test, then moves the Force bar into a plain overlay (so content scrolls under it), expects a failure, and restores the file |

"Before" is build 57's look: the same harness on the pristine base `48788ef`, with only the harness added.

## Artifact index

<!-- index:start -->
### Before/after sheets (one per state; before dark · after dark · before light · after light)

**iPhone 17 Pro**

- [Overview, every after state, dark](sheets/17pro-overview-dark.png)
- [Overview, every after state, light](sheets/17pro-overview-light.png)
- [Force · disconnected](sheets/17pro-force-disconnected.png)
- [Force · connected, Guided, nothing armed](sheets/17pro-force-guided-idle.png)
- [Force · connected, Guided, armed](sheets/17pro-force-guided-armed.png)
- [Force · recording](sheets/17pro-force-recording.png)
- [Force · connected, Hands-free, armed (waiting for pull)](sheets/17pro-force-handsfree-armed.png)
- [Force · interrupted (F3)](sheets/17pro-force-interrupted.png)
- [Force · scrolled to end (F5)](sheets/17pro-force-guided-armed-bottom.png)
- [Dashboard · readiness 38, load 0.66 (#1022/#1023)](sheets/17pro-dashboard.png)
- [Dashboard · scrolled to end (F5)](sheets/17pro-dashboard-bottom.png)
- [Workout · scrolled to end (F5)](sheets/17pro-workout-bottom.png)
- [History · scrolled to end (F5)](sheets/17pro-history-bottom.png)
- [Settings · scrolled to end (F5)](sheets/17pro-settings-bottom.png)

**iPhone SE (3rd gen)**

- [Overview, every after state, dark](sheets/se-overview-dark.png)
- [Overview, every after state, light](sheets/se-overview-light.png)
- [Force · disconnected](sheets/se-force-disconnected.png)
- [Force · connected, Guided, nothing armed](sheets/se-force-guided-idle.png)
- [Force · connected, Guided, armed](sheets/se-force-guided-armed.png)
- [Force · recording](sheets/se-force-recording.png)
- [Force · connected, Hands-free, armed (waiting for pull)](sheets/se-force-handsfree-armed.png)
- [Force · interrupted (F3)](sheets/se-force-interrupted.png)
- [Force · scrolled to end (F5)](sheets/se-force-guided-armed-bottom.png)
- [Dashboard · readiness 38, load 0.66 (#1022/#1023)](sheets/se-dashboard.png)
- [Dashboard · scrolled to end (F5)](sheets/se-dashboard-bottom.png)
- [Workout · scrolled to end (F5)](sheets/se-workout-bottom.png)
- [History · scrolled to end (F5)](sheets/se-history-bottom.png)
- [Settings · scrolled to end (F5)](sheets/se-settings-bottom.png)

**Apple Watch**

- [Overview, every after state, dark](sheets/watch-overview-dark.png)
- [Watch · Home / status](sheets/watch-watch-status.png)
- [Watch · Force gauge, connected](sheets/watch-watch-forceConnected-gauge.png)
- [Watch · Force gauge, live pull](sheets/watch-watch-forceLive-gauge.png)

**Mascots in the app** (approved vs refined candidate, real size)

- [sheets/mascot-in-app.png](sheets/mascot-in-app.png)

### Raw screenshots

- `screens/before/17pro/`: 16 PNGs (iPhone 17 Pro, before)
- `screens/before/se/`: 16 PNGs (iPhone SE (3rd gen), before)
- `screens/before/watch/`: 3 PNGs (Apple Watch, before)
- `screens/after/17pro/`: 24 PNGs (iPhone 17 Pro, after)
- `screens/after/se/`: 24 PNGs (iPhone SE (3rd gen), after)
- `screens/after/watch/`: 3 PNGs (Apple Watch, after)

### Specs, tools, gates

- [`tokens.md`](tokens.md): token table: every token, dark/light hex, where it is used, WCAG ratio for every text pair
- [`proposals.md`](proposals.md): P1–P11 for the owner to accept or reject, and what was deliberately left out
- [`mascots/mascot-sheet.png`](mascots/mascot-sheet.png): mascot before/after, dark and light, props shown
- [`mascots/out/force-1028-160.svg`](mascots/out/force-1028-160.svg): refined Force mascot (candidate)
- [`mascots/out/workout-1028-160.svg`](mascots/out/workout-1028-160.svg): refined Workout mascot (candidate)
- [`mascots/generate.py`](mascots/generate.py): deterministic mascot refinement
- [`mascots/verify.py`](mascots/verify.py): mascot gates: masters byte-pinned, determinism, pose overlap, holes, local drift, prop clearance
- [`tools/capture-phone.sh`](tools/capture-phone.sh): phone captures (status bar pinned, app proven frontmost)
- [`tools/capture-watch.sh`](tools/capture-watch.sh): Watch captures
- [`tools/stage-screens.sh`](tools/stage-screens.sh): raw captures to repo screenshots (50%, stripped, byte-stable); runs check-shots.py first
- [`tools/check-shots.py`](tools/check-shots.py): fail-closed check that every phone capture shows the app, not the splash or home screen
- [`tools/sheets.py`](tools/sheets.py): before/after sheets
- [`tools/tokens.sh`](tools/tokens.sh): compiles the shipped palette and writes or checks tokens.md
- [`tools/f5-gate.sh`](tools/f5-gate.sh): F5 UI test GREEN, plus a mutation that must turn it RED
- [`tools/index.py`](tools/index.py): this index
<!-- index:end -->
