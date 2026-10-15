# #1038 design round: Force tab — every recording full screen, "Free hold", armed by default, one-tap picker

Branch `design-1038-force`, base `origin/staging` @ `2ee391e` (= build 58). Locked spec: issue #1038 (G1–G6 + Safety)
plus the owner's **amendment H** (context card + picker visuals) and **amendment I** (Finish in the bar, Finish
disconnects). Look and tokens stay #1028's; nothing here touches staging, main or TestFlight.

**Start here on a phone:** `sheets/17pro-overview-dark.png` (every after state in one row), then the per-state
before/after sheets below. Defects fixed (H1–H7) and the owner's accept/reject list (HP1–HP13) are in **`proposals.md`**.

## What changed (spec item → where)

| Spec | Change | Code |
|---|---|---|
| **G1** | No live force on the tab: the gauge card, inline trace and readout are gone. Every recording happens in a full screen. Free hold has a **new full screen** in the guided one's language: glass top bar, the hold clock as the hero, live force with Peak/Avg, the chart filling the remaining height, and Stop & save only while a pull records. | `Features/Force/FreeHoldFullscreenView.swift`, `ForceView` |
| **G2** | "Hands-free" → **"Free hold"** on the bar switch, copy, accessibility labels and the Watch's idle-disarm message. The persisted raw value stays `handsFree`, so no stored switch or a11y id churns. | `ForceBarMode.title`, `TindeqManager.swift` |
| **G3** | Armed by default. Free hold self-arms on connect; the tab stays; **the full screen opens on the first pull** and stays for the next one until you leave it. Guided: picking a protocol arms it, the bar says "Armed · tap Start". | `FreeHoldAutoArmPolicy`, `FreeHoldPresentation.request` |
| **G4** | Picking a protocol in the context card switches the bar to Guided, including from Free hold. | `ForceProtocolSelectionRouting` |
| **G5** | The movement & side picker is a sheet that **applies and closes on the tap that completes it**: no X, swipe down keeps the current choice. A movement with a known last side commits in one tap; one with no side history waits for the side. | `MovementSidePickerPolicy`, `ForceRecordingContextCard` |
| **G6** | In place of the gauge card: a **last-pull summary** (peak, hold, movement, when). Tap opens that pull in History. Hidden with no pulls. | `ForceLastPullFormat`, `AppModel.focusHistory(on:)`, `HistoryView` |
| **I1** | The gauge session lives in the **sticky bar**: count plus a full-size (44 pt) **Finish**. The old caption row left the card. | `ForceBottomBar` session strip, `ForceBarState.session` |
| **I2** | **Finish = end the session, then disconnect**, as an explicit disconnect (no #1031 auto-reconnect). If the end fails, the Progressor stays connected. | `ForceFinishSequence.disconnects(after:)`, `AppModel.finishGaugeSessionAndDisconnect()` |
| **I3** | Finish is unavailable mid-recording, during a guided run and with an unsaved held pull, and says why. The count stays visible while blocked. | `ForceFinishPolicy.finishBlockedReason` |
| **I4** | Bar with an active session; the held-pull block; the state after Finish; Free hold's own Finish (proposed in the spec). | sheets `force-bar-session`, `force-held-pull`, `force-after-finish` |
| **H1–H7** | Defects, fixed: intensity ticks by value (one mapping for ticks, thumb and touch); no "Either" column; the Free hold chart's kg scale (#1028 F4); a fitted, labelled axis; the Best line labelled on the line; AA Finish and a primary Stop & save; an opaque collapsed title. Details and proofs: `proposals.md`. | |

### Safety (spec) — how each holds

- **No recording from noise.** Threshold and dwell are unchanged; `Force1038PickerAndSafetyTests.testASubThresholdWobbleNeverPresentsTheFullScreen` feeds the real hands-free machine a sub-threshold wobble and proves no full screen opens.
- **Auto-arm never mid-recording, with a held pull, during a guided run, while saving, disconnected, or after an
  explicit Disarm.** `Force1038PolicyTests.testAutoArmRules` (one assertion per rule).
- **Leaving the full screen keeps it armed.** Minimize only dismisses the cover (`onMinimize` sets
  `freeHoldFullscreenPresented = false`; it does not touch the arm state). Disconnect disarming is build 58's existing
  hands-free behaviour, unchanged here. Neither has a new dedicated test in this round — an implementation lane should
  add them.
- **Durable save path unchanged.** The release-saves path is the existing one; the salvage lock is taken when a pull starts recording (`Force1038WiringTests.testTheSalvageLockIsTakenWhenAPullStartsRecording`).

## Contrast (H6) — computed from the palette tokens

WCAG 2.x relative luminance over the composited background: phase tint (14 %) over the grouped background
(`#F2F2F7` light, `#000000` dark), then the button's 12 % danger fill.

| Control | Label | Optimal | Caution | Primary | Danger |
|---|---|---|---|---|---|
| Finish, build-58 style (raw `danger` label) | light | 2.2 | 2.3 | 2.1 | 2.2 — **fails** |
| Finish, `dangerText` (considered) | light | 3.9 | 4.1 | 3.7 | 3.9 — fails 4.5 |
| **Finish, `alertPillText` = `pillText(danger)` (shipped here)** | light | **5.9** | **6.3** | **5.7** | **6.0** |
| **Finish, `alertPillText`** | dark | **9.4** | **8.6** | **9.8** | **9.1** |
| **Stop & save**: `onPrimary` on `primary` | both | 5.4 | | | |

The Stop & save fill against the phase backgrounds: 4.0–4.4:1 light, 3.3–3.6:1 dark (≥ 3:1 non-text). Disabled
Finish (mid-pull, I3) uses the palette's `textDisabled`, which is not subject to AA.

## Run the prototype (real SwiftUI, real `MainTabView`, seeded data)

The DEBUG build has a design harness, `Sources/App/DesignFixture1038.swift`: one launch argument renders the real
screens over deterministic data, with no sign-in and no Progressor.

```sh
cd native/SendmeterNative && xcodegen generate
xcodebuild -project SendmeterNative.xcodeproj -scheme SendmeterNative -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/dd1038 CODE_SIGNING_ALLOWED=NO build
APP=/tmp/dd1038/Build/Products/Debug-iphonesimulator/Sendmeter.app
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.jirathip.sendlog.native --design-1038 force-free-hold-armed-last-pull
```

States (`--design-1038 <state>`, list in `tools/states-after.txt`): `force-free-hold-armed`,
`force-free-hold-armed-last-pull`, `force-free-hold-waiting`, `force-free-hold-recording`, `force-free-hold-saved`,
`force-guided-armed`, `force-zone-armed`, `force-disconnected`, `force-picker`, `force-picker-side`,
`force-bar-session`, `force-held-pull`, `force-after-finish`. The guided full screen is reached through its own #938
harness: `--guided-force-fixture=work` (one argument). The app is interactive: pull-free states can switch mode,
open the picker, change tab.

**Before (build 58):** `tools/base-harness/` holds the minimal DEBUG harness for `2ee391e` (`build58-harness.diff` +
`DesignFixture1038Base.swift`; `README.md` there has the exact worktree/apply/build steps). States:
`tools/states-before.txt`.

## Reproduce every artifact

| Artifact | Command (repo root) |
|---|---|
| Phone captures (3×/2× originals, private) | `design-output/1038/tools/capture-phone.sh <app> <udid> <capture-root>/{after,before}/{17pro,se} {after,before}-{17pro,se} $(cat design-output/1038/tools/states-{after,before}.txt)` — status bar pinned to 9:41, app proven frontmost before every shutter, dark then light |
| `screens/` (50 % copies) | `design-output/1038/tools/stage-screens.sh <capture-root>` — fail-closed `check-shots.py` first (every frame shows the app), metadata stripped; byte-identical on re-run |
| `sheets/` | `python3 design-output/1038/tools/sheets.py` — fixed layout, no timestamps; byte-identical on re-run |

Devices: iPhone 17 Pro (iOS 26, 402×874 pt @3× → 1206×2622 px; staged 603×1311) and iPhone SE 3rd gen
(375×667 pt @2× → 750×1334 px; staged 375×667). 28 after + 12 before captures per device, 0 capture retries.
The SHA-256 of every committed PNG and tool is in `SHA256SUMS` (regenerate: `design-output/1038/tools/sha256sums.sh`;
verify: `shasum -a 256 -c design-output/1038/SHA256SUMS` from the repo root).

## Screenshot index

Each sheet: BEFORE build 58 dark | AFTER dark | BEFORE light | AFTER light; states that did not exist on build 58
are after-only (dark | light). `<d>` = `17pro` or `se`.

| Sheet | Shows |
|---|---|
| `sheets/<d>-overview-{dark,light}.png` | every after state, one row |
| `sheets/<d>-force-free-hold-armed.png` | Free hold armed on connect, no live force on the tab (G1/G2/G3) — vs build 58's Hands-free gauge |
| `sheets/<d>-force-free-hold-armed-last-pull.png` | the last-pull summary in place of the gauge (G6); opaque collapsed title (H7) |
| `sheets/<d>-force-free-hold-waiting.png` | Free hold full screen, waiting for the next pull; Best line on the canvas |
| `sheets/<d>-force-free-hold-recording.png` | recording: kg scale, fitted axis, "Best 31.5" on the line, primary Stop & save (H3–H6) — vs build 58's inline recording |
| `sheets/<d>-force-free-hold-saved.png` | just saved: that pull's peak and whole trace, ready for the next pull; enabled Finish |
| `sheets/<d>-force-guided-armed.png` | Guided with a protocol picked = armed, Start in the bar (G3/G4); flat card (HP5–HP9) |
| `sheets/<d>-force-zone-armed.png` | suggested zone armed: intensity ticks by value (H1), one target row (HP6) |
| `sheets/<d>-force-disconnected.png` | disconnected ("Selected", not "Armed") |
| `sheets/<d>-force-picker.png` | movement & side picker: one tap applies and closes, grabber + "swipe down to keep" (G5, HP1–HP4, H2) |
| `sheets/<d>-force-picker-side.png` | a movement with no side history waits for the side (G5) |
| `sheets/<d>-force-bar-session.png` | session in the bar: count + Finish (I1) |
| `sheets/<d>-force-held-pull.png` | a held pull blocks Finish and says why (I3, #1004 controls) |
| `sheets/<d>-force-after-finish.png` | after Finish: session logged, Progressor disconnected (I2) |
| `sheets/<d>-guided-fullscreen-work.png` | the guided full screen, reached from Start — reference, unchanged |

Raw per-state screens: `screens/{before,after}/{17pro,se}/<version>-<device>-<state>-<scheme>.png`.

## Gates (at the committed head)

- `swift test` (native package): **1618 tests, 0 failures**. Watch core (`ios/App/SendLogWatchCore`): **605, 0**.
- Palette gate (`SendmeterPaletteGateTests`, in the run above): green — shared tokens only; the one new colour
  (`alertPillText`) is the palette's own `pillText(danger)` mix.
- `scripts/validate-anti-slop.sh`, `validate-anti-slop-cold.sh`, `check-docs-stale-commands.sh`,
  `assert-native-watch-project.rb`: all exit 0.
- Mascot masters and asset catalogs: **0 diff lines** vs `2ee391e`.
- App build (`xcodebuild`, generic iOS Simulator): BUILD SUCCEEDED; the captured binary is newer than every source file.
- Mutation probes for the Conductor-review fixes (each mutation alone turns a focused test RED; files restored
  byte-identically): kg scale dropped, zero-based axis, a private y-mapping, the raw Finish label, the soft title
  edge, half-kg steps, a raw-min (ramp) axis fit, no ramp exclusion, a forced-visible bar background (hid the title).

## Not in this round

- The guided full screen is unchanged (the brief's reference surface); "End" vs "Finish" is a proposal (HP13).
- The Watch: only the idle-disarm message is renamed (G2); no Watch screens were captured.
- The picker's "Recent" group and side history read existing pull history; no new storage.
- Watch: the rename is the one user-visible idle-disarm message; code comments that say "hands-free" were left alone.
