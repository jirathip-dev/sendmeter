# Evidence — impl-926 (issue #926: refused manual-workout End explains itself in the full screen)

All artifacts were produced on this host on 2026-09-19 by the lane's own
commands. Hashes: `hashes.txt`. Every `.gz` is the raw command log exactly as
`xcodebuild`/`swift test`/`just` wrote it; the raw exit code is appended inside
the log as `RAW_EXIT[name]=<code>`.

## What each artifact proves

| Artifact | Produced by | Proves |
|---|---|---|
| `just-fast.log.gz` | `just fast` (canonical run) | exit 0; core 1316 / watch-core 600 / health-core 66 tests, 0 failures; anti-slop wiring wrapper passed |
| `just-fast-attempt-incidents.log.gz` | transcription of the two earlier `just fast` launches | the lane's own duplicate launch raced the SwiftPM lock and the canonical run was killed at the harness cap; both raw logs kept |
| `gen.log.gz` | `just gen` | exit 0, project regenerated (new test files are in the generated project) |
| `build-ios-hang.log.gz` | `just build-ios` (brief's exact recipe) | hangs after "Build settings from command line" (Xcode DerivedData pinned to the unattached `/Volumes/NVMe2TB`); lane watchdog killed it at 240 s → `RAW_EXIT[build-ios]=143` |
| `build-local.log.gz` | same xcodebuild + `-derivedDataPath /Users/jirathip/impl926-derived` | `** BUILD SUCCEEDED **`, `RAW_EXIT[build-local]=0` |
| `apptests-attempt3-erased-sim.log.gz` | `xcodebuild test … -only-testing:SendmeterNativeTests CODE_SIGNING_ALLOWED=NO` on the freshly erased iPhone SE (3rd gen) `impl926-sim` | **87 tests, 0 failures**, `RAW_EXIT[apptests3]=0` — CI shape, no `-skip-testing` |
| `apptests-attempt2-stale-container.log.gz` | same command, same container, one run later | 87 tests / 11 failures in two pre-existing classes (`PhaseTransitionReplayAppTests`, `GuidedProtocolCompletionTests`) — the test container is shared across runs; the erased-sim rerun above is the authoritative green |
| `apptests-attempt1-infra.log.gz` | same command, first attempt | `Sendmeter (pid) encountered an error (The test runner hung before establishing connection.)`, 0 tests executed → infra, not a verdict |
| `uitests-attempt3-erased-sim.log.gz` | `xcodebuild test … -only-testing:SendmeterNativeUITests CODE_SIGNING_ALLOWED=NO` on the erased sim | the lane's 3 UI tests pass; `MenuActivationUITests` passes; `ErrorBannerDismissUITests.testTappingDismissRemovesLongErrorBanner` (pre-existing, #927) fails in suite order |
| `uitests-attempt2-stale-container.log.gz` | same command, one run earlier | same three lane tests pass; both `ErrorBannerDismissUITests` cases flake in suite order |
| `uitests-attempt1-infra.log.gz` | same command, first attempt | runner failed to initialize ("Timed out while loading Accessibility"), 0 tests → infra |
| `errorbanner-standalone.log.gz` | `-only-testing:SendmeterNativeUITests/ErrorBannerDismissUITests` | both pre-existing error-banner UI tests pass standalone, `RAW_EXIT=0` — the in-suite failures are harness-order flakes, not a product regression |
| `final-green.log.gz` | `-only-testing:SendmeterNativeUITests/ManualWorkoutEndRefusalUITests` on the committed head | 3 tests / 0 failures, `RAW_EXIT=0` |
| `probe.diff` + `red-probe-and-restore.log` | lane probe script | the RED mutation (refusal routed back to the banner-only, pre-fix presentation): anchor matched exactly once, `git hash-object` of the restored file equals the committed blob (`87b43c84…`), `RESTORE_MATCHES_GREEN=1` |
| `final-red.log.gz` | the same UI class on the mutated tree | the two discriminating tests FAIL (`a refused End must explain itself inside the full-screen workout`; `fixture: the refusal must be on screen before minimizing`), `RAW_EXIT=65` |
| `final-green-after-restore.log.gz` | the same UI class after the byte-identical restore | 3 tests / 0 failures, `RAW_EXIT=0` |
| `manual-workout-end-refusal-small-phone.png` | `simctl install` (verified) + `launch … --tabs-fixture workout --manual-workout-fixture=refused` + `simctl io screenshot` on the SE | the refusal is rendered inside the full-screen workout at the default text size; End still present |
| `manual-workout-end-refusal-small-phone-ax5.png` | same launch with `simctl ui … content_size accessibility-extra-extra-extra-large` | the same copy at AX5: every rendered line is complete (the tail continues below the fold and scrolls); End remains visible; the top bar wraps |
| `ui-test-manual-workout-end-refusal.png` | `xcrun xcresulttool export attachments` from the `final-green` run | the screenshot the UI test itself took at the moment of its assertions |
| `capture.log` | lane capture script | `simctl install` proof: `Sendmeter.debug.dylib` sha256 is identical in the built app and in the installed container before AND after both captures (`29da786a…`) |
| `harness-launch-flake-loginview-hierarchy.txt` | the flaked launch's own UI-hierarchy attachment | one launch in four did not take the fixture route (the app rendered the signed-out LoginView); the UI test's bounded relaunch guard exists because of it |
| `anti-slop-linter.log.gz` | `bash scripts/anti-slop-swift.sh native/SendmeterNative/Sources` | 158 files scanned, 1 advisory violation — pre-existing, in `Sources/Core/DirectWriteReplay.swift:197`, not in this lane's diff |

## What this evidence does NOT show

- No device rendering: both screenshots are simulator renders on an iPhone SE
  (3rd generation) iOS 26.5 simulator.
- No haptics observation: the accepted/refused cues were verified in source and
  by the existing #656/#222 guards, never on hardware.
- No hosted CI run: the workflow triggers on pull requests and on pushes to
  `main`/`staging`; this lane's branch is neither, and the brief forbids opening
  a PR — so there is no hosted run at this head to cite.
- No server-side count of the workout insert: the app-target test proves one
  durable intent and one pending session row; the stubbed transport in this
  harness does not model the `sessions` insert.
- The `ErrorBannerDismissUITests` in-suite flake is documented, not fixed: it
  is a pre-existing #927 test outside this issue's scope, and it passes
  standalone (log committed).
