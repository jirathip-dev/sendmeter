#1031 native/force: sticky Force bar, auto-reconnect, honest states (rollout #1028 slice 2/3)

Refs #1031 · Refs #1021 · approved reference `design-1028-refine` @ `fc1d8ada` (#1028) · base `impl-1030` @ `2a13b04` (merged to `staging` as `5cd56bd`)

This is slice 2 of the #1028 rollout, ported from the approved prototype code rather than merged. #1032 is slice 3.

## What changed

- **Sticky Force bar** (`ForceBottomBar`, driven by the pure `ForceBarPolicy`). It holds the device status dot, the protocol name (tap → protocol list), **Guided | Hands-free**, and one action that follows the mode:
  - Guided: Connect → Start → Stop & save.
  - Hands-free: Connect → Arm → pull, saving on release.
- **F1.** The bar is the only device status and Connect/Reconnect control. The Recording-device row and the Progressor card's status/pill/reconnect panel are gone. Every user Disconnect goes through `AppModel.requestDisconnect()`.
- **Auto-reconnect (#1021).** `ForceAutoReconnectPolicy` with `KnownProgressorStore`, plus a bounded reconnect to the known peripheral in `TindeqBluetooth`.
  - It runs on entering Force and on foreground (`scenePhaseChanged`).
  - It never runs after a user disconnect, until the next connect.
  - It never runs mid-session: a guided protocol or a hands-free arm/measure counts as a session.
- **Honest states.**
  - **F3 + P3:** disconnected reads "Waiting for Progressor"; the header reads "Selected protocol", and "Armed protocol" only with a live link.
  - **F4:** "Hold 30.3 s" plus a kg scale on the trace.
  - **P1:** the locked line mid free pull. **P2:** "Free pull". **P8:** a locked outlined chip with a lock glyph.
  - **P9:** an inline title while recording when the screen height is under 700 pt (SE).
  - **P11:** "Connection lost" only when a live link drops.
- **F5 + P4.** The bar sits in the bottom safe-area inset with an opaque backing under the tab bar and a 14 pt fade.
  - `TabBarClearanceUITests` now excludes the bars' subtrees structurally. The old geometric filter hid the very defect, so its RED probe did not bite.
- **#1004.** The Save Recovered Pull / Discard controls are unchanged and reachable. The bar reads "Unsaved pull · Save pull" while a pull is held.

## Not in this PR

- **Slice 3 (#1032):** `DashboardVerdict`, the sparse trend, the other tabs' edges, and the #1024 copy removals. One of these is visible on the Force sheets: the training-balance subtitle.
- **Not shipped at all:** the `DesignFixture1028` harness, its hooks, `progressorCardAnchor`, and candidate mascots. `git diff --stat origin/staging HEAD -- '*Mascot*'` is empty.

## Evidence

The evidence lives in [`docs/evidence/issue-1031/README.md`](docs/evidence/issue-1031/README.md).

- **Captures:** before / after / approved sheets for 10 Force states on iPhone 17 Pro and iPhone SE (3rd gen), each in dark and light.
  - `tools/compare-approved.py` measures every after capture against its approved twin.
- **RED probes:** 10 of 10 bite (5 core, 4 app, 1 UI on SE). Each reverts one rule; the exits and asserting lines are in the README.
- **Deviations for the owner:**
  - P9 makes the SE recording title inline. The approved SE capture predates P9.
  - Guided recording keeps the armed protocol card. That is the prototype's own rule, and there is no approved capture of this state.
  - P9 needed two fix-forward commits (`8430e69`, `e1bd3b0`). The README explains why.

### Gates

Source head `e1bd3b0`. The commits after it touch `docs/evidence/issue-1031/` only. Each gate has a named log and its raw exit; the summary is `logs/gates-summary.txt`.

| Gate | Raw exit | Log |
|---|---|---|
| `just core` | 0 (1566 tests, 0 failures) | `logs/gate-core.log.gz` |
| `just watch-core` | 0 (605 / 0) | `logs/gate-watch-core.log.gz` |
| `just slop` | 0 | `logs/gate-slop.log.gz` |
| `just gen` | 0 | `logs/gate-gen.log.gz` |
| `just check-static` | 1 (recorded base red: `ManualForceFullscreen.swift`) | `logs/gate-check-static.log.gz` |
| `xcodebuild build`, generic iOS Simulator, `CODE_SIGNING_ALLOWED=NO`, lane-local DerivedData | 0 (`** BUILD SUCCEEDED **`) | `logs/gate-build-ios-unsigned.log.gz` |
| `xcodebuild test -only-testing:SendmeterNativeTests` | 0 (194 tests, 0 failures) | `logs/gate-app-suite.log.gz` |
| UI smoke (`MenuActivationUITests`, `ManualWorkoutEndRefusalUITests`) + `TabBarClearanceUITests`, iPhone SE (3rd gen) | 0 (5 tests, 0 failures; window 375.0×667.0) | `logs/gate-ui-smoke-clearance-se.log.gz` |
| `git diff --check 2a13b04..HEAD` | 0 (empty output) | `logs/gate-diff-check.log` |
| `git diff --stat origin/staging HEAD -- '*Mascot*'` | 0 (0 bytes) | `logs/mascot-identity.log` |

Notes on the gates:

- **`git diff --check 2a13b04..HEAD` instead of `origin/impl-1030..HEAD`.** The `impl-1030` branch was deleted when #1033 merged. `2a13b04` is its head, so the range is identical.
- **`just check-static` exit 1 is the brief's recorded base red.** `validate-native-static.sh` still requires `ManualForceFullscreen.swift`, which the base no longer has.
- **`just core` hung once and was cut off once before going green.**
  - Run 1 hung in the untouched `GuidedForceTerminalSettlementTests.testConcurrentTerminalCallersJoinOneSettlement`.
  - Run 2 died when the host disk filled.
  - The run at `e1bd3b0` is green, and that test passed.
  - Both earlier logs are kept.
- **Simulators.** The host's `xcodebuild` shim runs `test` on a `hermes-sim-task` temporary simulator. The SE gates pass `--device-type` for the iPhone SE (3rd gen).
