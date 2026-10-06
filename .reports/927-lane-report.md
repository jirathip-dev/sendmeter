# Lane report — #927 follow-up (impl-927b): large title rendered over the shared ErrorBanner

- STATUS: DONE (code, tests, evidence). Owner physical-device check: NOT mine, left open.
- Base: `origin/staging` `c55b06c`. Branch: `impl-927b`. Head: the commit that carries this report
  (sha in the final lane message). Orchestrator preservation commit `2e1b34f` is in the history; it had a
  syntax error (old `ErrorBanner` body tail left dangling) that this commit fixes.
- No PR, no merge, issue untouched (`hold:human-gate` kept).

## Root cause

`RootView` drew the banner in a root `.overlay(alignment: .top)`. An overlay reserves no layout space, so every
tab's `NavigationStack` laid its UIKit navigation bar (and large title) out at the top safe area — i.e. under
the banner — and drew the title through the message (build-57 screenshot).

## Fix

- `SendmeterNativeApp.swift`: new `ErrorBannerHost` (RootView now hosts every screen in it). The banner stays in
  the top overlay (window safe area, never scrolls); its rendered height is measured with `onGeometryChange`,
  and while a banner shows the screen is **padded down** by `height + 8`, so every navigation bar / large title
  is laid out below the banner's bottom edge. Dismissing hands the space back.
  - Measured, not assumed: the first attempt used `.safeAreaPadding(.top, …)` (what `2e1b34f` carried). It
    does **not** reach the UIKit navigation bars a `NavigationStack` hosts — the layout test stayed RED
    (`.reports/927-red-safeAreaPadding-variant.log`, `RAW_EXIT=65`, 20 failures). Plain layout padding is what
    moves the bars.
  - DEBUG `--error-banner-fixture short|long|unreadable` harness now raises the REAL banner through
    `model.errorMessage` (real `UserFacingError` copy, unchanged) and RootView's real host draws it; combined with
    `--tabs-fixture <tab>` the screen underneath is the real `MainTabView`. It is checked before
    `--tabs-fixture` in the DEBUG launch switch so both flags compose.
- `DesignSystem.swift` (`ErrorBanner`): opaque backing (nothing under it shows through); at accessibility text
  sizes the glyph + ✕ sit on a top row and the message spans the full banner width (it was squeezed into a
  narrow column beside the 44 pt control). The dismiss control is one `DismissControl` view placed by both
  layouts — same 44×44 target, `Dismiss error` label, `error-banner-dismiss` identifier, haptic button style.
  Announcement policy and hit-testing untouched. Copy untouched.

## Acceptance criteria

| AC | Result | Command → raw exit → log |
| --- | --- | --- |
| Banner text + ✕ legible, never overlapped, Dashboard **and every large-title tab**, default **and** largest Dynamic Type | **met** | `ErrorBannerLargeTitleLayoutTests` (all 5 tabs × default/AX5, reads each tab's laid-out `UINavigationBar` + large-title `UILabel` frame vs the banner's rendered bottom) → `RAW_EXIT=0` → `.reports/927-focused-green-3.log`; also in the full app-target run below. UI test `testDashboardLargeTitleStaysBelowTheBanner` (real app, real Dashboard, XCUI frames + `isHittable` + tap-to-dismiss) → `RAW_EXIT=0` → `.reports/927-uitests-banner.log` |
| #950 contract preserved (44 pt target, label, one-shot announcement, hit-testing) | **met** | `ErrorBannerAccessibilityTests` 5/5 (unchanged assertions; one pin ADDED for the host) + `StructuralHapticsWiringTests` 6/6 + `ErrorBannerDismissUITests` short/long 2/2 → `.reports/927-focused-green-3.log` `RAW_EXIT=0`, `.reports/927-uitests-banner.log` `RAW_EXIT=0` |
| Decorative/structural layers never intercept the dismiss target | **met** | `StructuralHapticDiagnosticBanner` keeps `.allowsHitTesting(false)` and sits below the error banner in the same overlay stack; UI tests assert `error-banner-dismiss` `isHittable` and that tapping removes the banner (3/3 passed, `.reports/927-uitests-banner.log`) |
| Simulator evidence: real banner over real Dashboard, default + largest | **met** | `docs/evidence/issue-927/` (README, `SHA256SUMS`); capture log `.reports/927-evidence-capture.log` (every launch/shot `exit=0`); installed-bundle proof `.reports/927-evidence-dylib.sha` (build output == installed container) |
| Discriminating test, fails before / passes after | **met** | RED/GREEN pair below |
| Native app tests/build pass | **met, with one disclosed load flake** | see Gates |
| Unreleased note | **met** | `RELEASE_NOTES.md` `## Unreleased` → `### Fixed`, first bullet |
| Owner physical-device check | **owner-gated — unchecked** | VoiceOver spoken output / haptics / device residuals stay with #881 |

## RED → GREEN (discriminating test)

Command (both runs, iPhone 16 Pro sim `5DA3EE07-…`, lane `-derivedDataPath ./.dd`):

```
xcodebuild test -project native/SendmeterNative/SendmeterNative.xcodeproj -scheme SendmeterNative \
  -destination "platform=iOS Simulator,id=<udid>" -derivedDataPath ./.dd CODE_SIGNING_ALLOWED=NO \
  -only-testing:SendmeterNativeTests/ErrorBannerLargeTitleLayoutTests
```

- **RED** — `DesignSystem.swift` restored to base `c55b06c` and the host's top padding removed (the base
  overlay-only shape): `RAW_EXIT=65`, `Executed 3 tests, with 22 failures` → `.reports/927-red-base-layout.log`.
  E.g. default size: `Dashboard's navigation bar starts at 62.0 pt, inside the banner (bottom 183.5 pt)` and its
  large title at 86.7 pt; largest size: banner bottom 1228.5 pt vs bar at 62.0 pt. Same for Force, Workout,
  History, Settings. `testTheLongestCopyStaysOnScreen…` also fails on the base banner (the AX5 squeezed column
  runs off screen).
- RED (variant) — `safeAreaPadding` instead of padding: `RAW_EXIT=65`, 20 failures →
  `.reports/927-red-safeAreaPadding-variant.log` (title tests fail; on-screen test passes because the banner
  layout fix is present).
- **GREEN** — fix restored byte-identical (sha1 `f6c03e89…` DesignSystem / `7439a0f9…` App, from the scratch
  backup): `RAW_EXIT=0`, `Executed 14 tests, with 0 failures` (with the #950 suites) →
  `.reports/927-focused-green-3.log`; and inside the full app-target run.
- Note: the source changed once after GREEN-3 (`dismissButton` → private `DismissControl` view, a pure
  extraction to satisfy a Core source pin; see Gates). Every gate below ran on the final source.

## Gates (final source unless noted)

| Gate | Raw exit | Log |
| --- | --- | --- |
| `just --list` | 0 | `.reports/927-just-list.log` |
| `just gen` (xcodegen, after adding the new test file) | 0 | `.reports/927-gen.log` |
| `cd native/SendmeterNative && swift build && swift test` | **0** — `Executed 1523 tests, with 0 failures` | `.reports/927-swift-build-test.log` |
| ↳ first run (before the extraction) | 1 — 1 failure: `HistoryTapDetailWiringTests.testPreviouslySilentStructuralControlsOwnTheirTicks` pins the literal `Haptics.shared.playGesture(.light)\n            dismiss()` at the base indentation; fixed structurally (body moved to a one-level `DismissControl`), pin untouched | `.reports/927-swift-build-test-1-pin-red.log` |
| `xcodebuild test … -only-testing:SendmeterNativeTests` (full app target) | **65** — `Executed 182 tests, with 1 failure`: `ForceLockOrphanAppTests.testTheReleaseOverAnEndedSessionLeavesThePendingRowUntouched` timed out (60 s waiting for the account bootstrap refresh) while host load was ~23–37 (other lanes' builds). All 8 ErrorBanner + 6 StructuralHaptics tests passed in this run | `.reports/927-app-target-full.log` |
| ↳ that suite re-run alone, same build | **0** — `Executed 3 tests, with 0 failures` (the failed test passed in 0.72 s) | `.reports/927-forcelockorphan-standalone.log` |
| `xcodebuild test … -only-testing:SendmeterNativeUITests/ErrorBannerDismissUITests` | **0** — 3/3 | `.reports/927-uitests-banner.log` |
| `scripts/anti-slop-swift.sh native/SendmeterNative/Sources` | 1 — 2 violations, both pre-existing at base and outside the fence (`AppModel.swift:9440`, `Core/DirectWriteReplay.swift:200`); identical on base `c55b06c` (`RAW_EXIT=1`, same 2) → **zero delta** | `.reports/927-anti-slop.log`, `.reports/927-anti-slop-base-c55b06c.log` |
| `git diff --check` | 0 | `.reports/927-git-diff-check.log` |

The ForceLockOrphan timeout is in a test this lane does not touch (Force session-lock bootstrap, #1004); it passed
standalone on the same build. I classify it as a load-induced timeout and did not rerun the full target a second
time (host rule: one xcodebuild, other lanes queued).

`.reports/927-focused-green-1.log` was NOT kept as evidence: it ran before `just gen` picked up the new test
file, so the new class did not execute (superseded by `-3`).

## Evidence (`docs/evidence/issue-927/`, iPhone 16 Pro sim, iOS 26.5, 1206×2622)

Real banner (`model.errorMessage`, real copy) drawn by RootView's real `ErrorBannerHost` over the real
`MainTabView`; text size via `xcrun simctl ui <udid> content_size large|accessibility-extra-extra-extra-large`.

- `dashboard-default-light.png`, `dashboard-default-dark.png` — default size: the full build-57 message (4 lines)
  and ✕ in an opaque banner; the Dashboard large title starts below it.
- `dashboard-largest-light.png`, `dashboard-largest-dark.png` — largest size: glyph + ✕ on the top row, the whole
  message across the banner width, ending "account."; nothing draws over it; the Dashboard title starts below it.
- `dashboard-largest-longest-light.png` — largest size, longest copy (device-clock nudge), whole message
  ("…then try again.") and ✕ visible.
- `force-/workout-/history-/settings-largest-light.png` — the other large-title tabs at the largest size: banner
  whole, title below.

At the largest size the banner takes most of the screen and the tab content (title first) is pushed below it,
reachable again by dismissing — a deliberate trade: nothing may draw over the failure message.

## Files touched (vs base `c55b06c`)

- `native/SendmeterNative/Sources/App/SendmeterNativeApp.swift` — fenced-in
- `native/SendmeterNative/Sources/App/DesignSystem.swift` — fenced-in
- `native/SendmeterNative/Tests/SendmeterNativeTests/ErrorBannerLargeTitleLayoutTests.swift` — new, ErrorBanner test
- `native/SendmeterNative/Tests/SendmeterNativeTests/ErrorBannerAccessibilityTests.swift` — one pin ADDED, none weakened
- `native/SendmeterNative/Tests/SendmeterNativeUITests/ErrorBannerDismissUITests.swift` — one UI test added, doc comment updated
- `docs/evidence/issue-927/**`, `.reports/**`
- `RELEASE_NOTES.md` — not in the brief's edit list, but its AC requires the Unreleased note; one bullet only.

Not touched: `Sources/Core/**` (incl. `FriendlyError.swift`), `Sources/Data/**`, `Sources/App/AppModel.swift`,
banner copy. `Package.resolved` was rewritten by `swift build` and restored before commit.

## Deferred / not verified

- Gate logs (`.reports/927-*.log`) are git-ignored by the repo (`.gitignore:3: *.log`) and were NOT force-added:
  they stay in this worktree at the paths cited above; this report quotes their decisive lines. Committed:
  this report, `.reports/927-evidence-dylib.sha`, `.reports/927-sim-udid.txt`.
- Owner physical-device check and VoiceOver spoken output / haptics (owner, #881).
- Full app-target run is not clean in one invocation (1 load timeout, passed standalone) — see Gates.
- Simulator shut down at the end of the lane; the lane sim (`.reports/927-sim-udid.txt`) is kept for re-runs.
