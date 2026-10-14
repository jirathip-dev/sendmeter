# #1031: Force sticky bottom bar, auto-reconnect, honest states (rollout #1028 slice 2/3)

Branch `impl-1031` is cut from `impl-1030` @ `2a13b04`. That is slice 1's reviewed head; #1033 has since merged it into
`origin/staging` as merge commit `5cd56bd`, so `2a13b04` is an ancestor of staging. The approved reference is
`design-1028-refine` @ `fc1d8ada` (`design-output/1028/`). This branch ports the slice-2 surface by hand. It is not a
merge of the design branch.

Source head: **`e1bd3b0`**. Every commit after it touches `docs/evidence/issue-1031/` only.

## What shipped

| AC (#1031) | Change | Evidence |
|---|---|---|
| Sticky bottom bar: status dot, protocol name (tap → list), **Guided \| Hands-free**, one action that follows the mode | New `ForceBottomBar` view, driven by the pure `ForceBarPolicy` (`Core/ForceBarPolicy.swift`). Guided runs Connect → Start → Stop & save; Hands-free runs Connect → Arm → pull, which saves on release. The bar sits in the scroll view's bottom safe-area inset. | `ForceBarPolicyTests` (`testGuidedSequence`, `testHandsFreeSequence`, `testGuidedNothingArmedChoosesAProtocol`, `testArmedNameOpensTheList`); every sheet |
| **F1**: the bar is the only device status and Connect/Reconnect control | Removed the Recording-device row (`ForceRecordingContextCard`) and the Progressor card's status, pill and reconnect panel (`ForceView`). Every user Disconnect / Cancel goes through `AppModel.requestDisconnect()`. | `EmptyStateWiringTests` (`"Recording device"` absent from the card; Connect only via the bar); sheets `*-force-disconnected`, `*-force-guided-armed` |
| **Auto-reconnect** to the last Progressor on entering Force or on foreground; never after a user disconnect, never mid-session (#1021) | Pure rule `ForceAutoReconnectPolicy` plus `KnownProgressorStore` (`Core/ForceAutoReconnect.swift`). `TindeqBluetooth` gains a bounded reconnect to the known peripheral. `AppModel.autoReconnectProgressor(_:)` runs on Force entry and from `scenePhaseChanged(.active)`. `userDisconnectedProgressor` blocks it until the next connect, and a guided protocol or a hands-free arm/measure counts as a session. The `ProgressorLink` closure seam is the test fake. | Core: `ForceAutoReconnectPolicyTests` (6). App: `ForceAutoReconnectAppTests` (10), `logs/app-autoreconnect.log` |
| **F3 + P3**: disconnected → "Waiting for Progressor"; "Selected protocol", and "Armed protocol" only with a live link; never "Live readout" / "Armed now" without a device | `ForceContextReadiness` (`Core/ForceBarPolicy.swift`) decides the claim (`waitingForProgressor` hides the live readout), the head word, the target badge and the start hint; `ForceRecordingContextCard` renders them. | `testContextCardWaitsForProgressorWhenDisconnected`, `testContextCardClaimsFollowTheMode`; sheets `*-force-guided-idle`, `*-force-disconnected` |
| **F4**: "Hold 30.3 s" plus a light kg scale | `ForceReadoutFormat.hold(milliseconds:)`, `ForceTraceScale.ticks(maxValue:)` | `testHoldLabel`, `testTraceScaleTicks`; sheets `*-force-recording` |
| **F5 + P4**: nothing scrolls under the tab bar or the Force bar; a 14 pt fade; no card-edge sliver at rest | The bar sits in `.safeAreaInset(edge: .bottom)` with an opaque canvas backing that runs under the tab bar, plus a 14 pt canvas fade above it. `TabBarClearanceUITests` now excludes the tab bar and the `force-bottom-bar` subtrees **structurally**, not by geometry. The old geometric filter also hid a content row sitting entirely behind the bar, which is exactly the F5 defect, so its RED probe did not bite (`red_exit=0`, see below). | GREEN on iPhone SE (3rd gen), window 375×667: the last row ends at y 410.5, above the bars at 449 (`logs/ui-clearance-se.log`). RED below. Sheets `*-force-guided-armed-bottom` |
| **P1**: mid-pull the context card collapses to one locked line. **P2**: Hands-free armed reads "Free pull". **P8**: a locked mode switch is an outlined chip with a lock glyph | `ForceRecordingContextCard` locked row and "Free pull" copy; `ForceBottomBar` locked chip (`ForceBarState.modeLocked`). | `testModeSwitchLocks`; sheets `*-force-recording` (P1, P8), `*-force-handsfree-armed` (P2), `*-force-guided-recording` (P8 "Guided" chip) |
| **P9**: compact heights collapse the large title while recording | `ForceTitlePolicy.collapsesLargeTitle(screenHeight:recording:)` uses a limit of 700 pt. `ForceView` feeds it the window scene's **screen** height: 667 pt on an SE, 874 pt on a 17 Pro. A measured view height was wrong twice (see "Fix-forward" below). | `testCompactHeightCollapsesTheTitleOnlyWhileRecording`; sheets `se-force-recording` (inline title) and `17pro-force-recording` (large title kept) |
| **P11**: interrupted mid-pull → "Connection lost"; plain idle stays "Disconnected" | `AppModel.progressorConnectionLost` is set only when a **live** link drops. A cold Bluetooth-off, a failed first connect, or a user Disconnect all read "Disconnected". | `testInterruptedSaysConnectionLost`, `testOnlyADroppedLiveLinkReadsAsConnectionLost`, `testUserDisconnectIsNeverConnectionLost`; sheets `*-force-interrupted` |
| #1004 recovery controls (Save / Discard / held pull) keep their behaviour and stay reachable | They are unchanged in the device card (`Save Recovered Pull` / `Discard`). The bar reads "Unsaved pull" with "Save pull" while a pull is held (`ForceBarPolicy`). | `testHeldPullIsReachableFromTheBar`; sheets `*-force-held` and `*-force-held-progressor` (scrolled: both controls fully above the bar) |
| Mascot masters byte-identical; no candidate mascots, no DEBUG design switch | `git diff --stat origin/staging HEAD -- '*Mascot*'` exits **0** with **0 bytes** of output. No imageset was added. `Sources/` mentions `1028` only in `#1028` comments plus slice 1's chalk seed `0x404`. | `logs/mascot-identity.log` (0 bytes) |
| Palette gate stays green | No colour literal was added; the new views use `SendmeterStyle` / `SendmeterPalette` tokens. | `SendmeterPaletteGateTests` inside `logs/gate-core.log.gz` (exit 0) |

## Not ported on purpose

- Slice 3 (#1032): `DashboardVerdict`, the sparse readiness trend, `.sendmeterTabBarEdge()` for the other tabs, and the
  #1024 copy removals. One of these is visible on the Force sheets: `ZoneFocusCard`'s "Last 4 weeks · this exercise only ·
  sets, not sessions" (approved: "Last 4 weeks · this exercise").
- The design harness: `DesignFixture1028.swift`, its `AppModel` / `TindeqBluetooth` / `SendmeterNativeApp` / `ForceView`
  hooks, `progressorCardAnchor` and the fixture scroll. `TabMascot` / Hero test changes and `ForceGaugeView` stay out
  too.

## Before / after vs the approved sheets

`tools/apply-harness.py <tree>` splices the design round's `DesignFixture1028` harness into a **scratch** worktree by
anchor (`harness.patch` no longer applies at this head). It adds three states:

- `force-guided-recording`
- `force-held`: the #1004 hold, with the drop delivered before the held buffer. A held pull handed to the drop handler is
  auto-saved by #678, so it would never show.
- a `@progressor` scroll, which uses the lane's own `ScrollViewReader`.

`forceInterrupted` now connects first and then interrupts, so it is a live drop.

The trees:

- **before**: `2a13b04` + harness
- **after**: source head + harness. The capture tree is `8430e69` with `e1bd3b0`'s `ForceView.swift` copied in, so its
  sources equal `e1bd3b0`.

Nothing from the harness is committed as app code. To reproduce, run `tools/capture-all.sh <before-tree> <after-tree>
<root>`, which drives `../issue-1030/tools/capture-phone.sh`, then `tools/stage-screens.sh <root>` and
`tools/sheets.py <approved-screens>`. The simulators were iPhone 17 Pro and iPhone SE (3rd gen) on iOS 26.5, in dark
and light. `tools/check-shots.py`: "76 captures show the app".

Each sheet shows **before · after · approved #1028**, dark then light. A state the approved round did not capture has
no third column.

| State | iPhone 17 Pro | iPhone SE | Visible difference after vs approved |
|---|---|---|---|
| Disconnected (F1, F3) | [sheet](sheets/17pro-force-disconnected.png) | [sheet](sheets/se-force-disconnected.png) | None: 0.00 % of pixels differ above the home indicator, on both phones. |
| Guided, nothing armed (F3 + P3) | [sheet](sheets/17pro-force-guided-idle.png) | [sheet](sheets/se-force-guided-idle.png) | None (0.00 %, as above). |
| Armed protocol | [sheet](sheets/17pro-force-guided-armed.png) | [sheet](sheets/se-force-guided-armed.png) | None (0.00 %, as above). |
| Armed, scrolled to the end (F5 + P4) | [sheet](sheets/17pro-force-guided-armed-bottom.png) | [sheet](sheets/se-force-guided-armed-bottom.png) | The last row ends above the bar in both. The recent-recording timestamps differ (capture date). |
| Guided recording (P1, P8, F4) | [sheet](sheets/17pro-force-guided-recording.png) | [sheet](sheets/se-force-guided-recording.png) | No approved twin. Before: the full armed card plus the "Recording device" row. After: the bar reads Recording · locked "Guided" chip · "26.5 kg · Hold 30.3 s" · Stop & save. See deviation 2 for the card. |
| Hands-free recording (P1, P8, P9, F4) | [sheet](sheets/17pro-force-recording.png) | [sheet](sheets/se-force-recording.png) | **SE:** the title is inline (P9, deviation 1), so the trace sits about 26 pt higher than in the approved capture. **17 Pro:** the large title stays, as approved. |
| Hands-free armed (P2) | [sheet](sheets/17pro-force-handsfree-armed.png) | [sheet](sheets/se-force-handsfree-armed.png) | **17 Pro:** the slice-3 training-balance subtitle only. **SE:** none (0.00 %); the subtitle is out of frame. |
| Interrupted mid-pull (P11) | [sheet](sheets/17pro-force-interrupted.png) | [sheet](sheets/se-force-interrupted.png) | The bar reads "Connection lost". The approved capture's fixture read "Disconnected", because it never had a live link; P11 is the accepted proposal. |
| #1004 held pull, top | [sheet](sheets/17pro-force-held.png) | [sheet](sheets/se-force-held.png) | No approved twin. After: the bar reads "Unsaved pull" · Save pull. |
| #1004 held pull, scrolled to the device card | [sheet](sheets/17pro-force-held-progressor.png) | [sheet](sheets/se-force-held-progressor.png) | After only: the base has no `ScrollViewReader` to scroll with. "Save Recovered Pull" and "Discard" sit fully above the bar on both phones. |

**Measured, not eyeballed:** `tools/compare-approved.py` (`logs/compare-approved.log`, exit 0) diffs the 28 after
captures that have an approved twin. For each one it reports the share of pixels that differ by more than 16, and their
bounding box in points, both for the whole frame and with the bottom 16 pt (the simulator's home indicator) excluded.

- **SE, identical: 0.00 %, no box.** Disconnected, guided idle, armed, and Hands-free armed, in both schemes. The
  slice-3 subtitle is below the fold on SE.
- **17 Pro, identical above the home indicator: 0.00 %.** Disconnected, guided idle, armed, and recording. The
  whole-frame 0.22 % is the home-indicator strip (simulator chrome); above it, only a few pixels differ (x 197–206,
  y 810–819 pt).
- **17 Pro Hands-free armed: 0.13–0.14 %.** Bounded to x 175–309, y 537–812: the slice-3 training-balance subtitle.
  "Free pull", "Armed · pull to start", the lock chip and Disarm all match.
- **Interrupted: 0.23 % on 17 Pro, 0.35–0.36 % on SE.** The SE box is x 43–155, y 476–488, which is the bar's status
  word: "Connection lost" (P11) vs the approved fixture's "Disconnected".
- **Scrolled to the end: 1.10–1.29 %.** Inside the recent-recordings list: the rows are dated from the capture day
  ("7 Oct … 11:37 AM" vs approved "6 Oct … 8:13 PM").
- **SE recording: 6.44–6.46 %.** Bounded to x 15–360, y 36–441: the P9 inline title and the trace moving up with it.

## Deviations (owner's call, not invented)

1. **P9 on SE vs the approved SE recording capture.** The approved captures predate the P9 proposal, so the approved SE
   recording still shows the large title. P9 is what this slice was asked to add ("Capture SE recording"), so the
   after-SE recording differs from the approved capture by design.
2. **Guided recording keeps the armed protocol card.** P1's locked line replaces the card only in free-pull recording.
   That is `ForceRecordingContextCard`'s `locked && !showsArmedHero`, byte-for-byte the approved prototype's rule.
   Mid-guided, the armed hero (protocol, target band, the "Ready · Start from the bar" hint) stays visible, and nothing
   on it is editable. The approved round has no guided-recording capture to compare against.

## Fix-forward on P9 (why there are three commits on one rule)

- `dcd071e` measured the ForceView's own geometry plus its safe-area insets.
- `8430e69` measured a clear `ignoresSafeArea()` background layer.
- Both read below 700 pt on a 17 Pro: the captures collapsed its title mid-pull, unlike the approved 17 Pro sheet.
- `e1bd3b0` reads `UIWindowScene.screen.bounds.height` instead, because the device class is the screen, not a measured
  view.

The superseded capture sets were deleted, not committed.

## Gates (raw exits)

See the table in `PR_BODY.md`. The summary is `logs/gates-summary.txt`; logs are gzipped so `git diff --check` stays
clean.

## Gate proofs (RED probes)

`tools/red-probes.sh <probe> <log-dir>` reverts **one** rule, runs the focused test to a named log, and restores the file
with `git checkout`. Core probes then re-run GREEN. App and UI probes run under `hermes-sim-task` on a fresh temporary
simulator. The UI probe's log records a 375.0×667.0 window (iPhone SE 3rd gen). The app-logic probe logs name only
the temporary simulator id, not its device type, so I do not claim a device for them; they assert model logic, not
layout.

| Probe | Planted defect | Focused test | RED exit (asserting line) | GREEN |
|---|---|---|---|---|
| `core-p11` | interrupted → `disconnectedWord` | `ForceBarPolicyTests/testInterruptedSaysConnectionLost` | **1** (`:87`) | 0 |
| `core-p9` | drop the `recording &&` guard | `ForceBarPolicyTests/testCompactHeightCollapsesTheTitleOnlyWhileRecording` | **1** (`:101`) | 0 |
| `core-rule1` | down link → no reconnect | `ForceAutoReconnectPolicyTests/testReconnectsOnEnteringForceAndOnForeground` | **1** (`:30`) | 0 |
| `core-rule2` | delete the user-disconnect guard | `ForceAutoReconnectPolicyTests/testDoesNotReconnectAfterAUserDisconnect` | **1** (`:39`) | 0 |
| `core-rule3` | delete the mid-session guard | `ForceAutoReconnectPolicyTests/testDoesNotReconnectMidSession` | **1** (`:47`) | 0 |
| `app-rule1` | drop `autoReconnectProgressor(.foreground)` from `scenePhaseChanged` | `ForceAutoReconnectAppTests/testForegroundOnForceReconnectsThroughScenePhase` | **65** (`:64`) | 0 (`logs/app-autoreconnect.log`) |
| `app-rule2` | never set `userDisconnectedProgressor` | `…/testUserDisconnectStopsAutoReconnectUntilTheNextConnect` | **65** (`:90`) | 0 |
| `app-rule3` | `sessionActive: false` | `…/testGuidedProtocolBlocksAutoReconnect` | **65** (`:109`) | 0 |
| `app-p11` | every interrupted reads as lost | `…/testOnlyADroppedLiveLinkReadsAsConnectionLost` | **65** (`:132`) | 0 |
| `ui-clearance` | the bar in `.overlay(alignment: .bottom)` instead of the inset | `TabBarClearanceUITests` on SE | **65** (`:78`; the last row ends at 551.5, under the bar at 449) | 0 (`logs/ui-clearance-se.log`) |

The `ui-clearance` summary also records the earlier run that did **not** bite (`red_exit=0`, geometric exclusion). That
run is why the test changed in `2a39c16`.

## `just core` on this host

- **Run 1** hung in `GuidedForceTerminalSettlementTests.testConcurrentTerminalCallersJoinOneSettlement`
  (`logs/gate-core-run1-hung.log.gz`). This lane does not touch that class: `git diff 2a13b04 HEAD` is empty for its
  file. A `sample` of the hung test process showed its main thread in `waitForExpectations`.
- **Run 2** died when the host disk filled (`logs/gate-core-run2-disk-full.log.gz`).
- **Run 3**, at the source head `e1bd3b0` after the disk was cleared, exited **0**: 1566 tests, 0 failures, and the same
  test passed (`logs/gate-core.log.gz`). I classify the hang as host-load flakiness in a pre-existing async test, not a
  lane defect.
- At base, `swift test --filter GuidedForceFullscreenPresentationTests` (31 tests, the presentation class only) passes:
  `logs/base-2a13b04-guided-fullscreen.log.gz`. That filter did not select the settlement class, so it is no base
  witness for the hung test; run 3 is the witness that the test passes.

## Tools

- Copied from `docs/evidence/issue-1030/tools/` and re-pointed: `stage-screens.sh`, `sheets.py` (with #1031 state
  titles) and `check-shots.py`. `capture-all.sh` drives `../issue-1030/tools/capture-phone.sh`.
- New here: `apply-harness.py`, `capture-all.sh`, `compare-approved.py`, `red-probes.sh` and `gates.sh`.
