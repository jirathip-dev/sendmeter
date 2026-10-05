# Evidence — sendmeter issue #1004 (lane `impl-1004`)

Everything here was produced in THIS lane's worktree
(`/Users/jirathip/.herdr/worktrees/sendmeter/impl-1004`) at the head named in
`.report-1004.md` §7. Nothing here is device evidence; the device-only items are
listed at the bottom.

## The named logs, one per command, each ending with the raw `EXIT=<code>`

The lane wrote every focused command's output to a named log under
`docs/evidence/issue-1004/logs/` while working (that plaintext set is still on
the machine). The repo's `.gitignore` ignores any `logs/` directory, so the
COMMITTED evidence is the gzipped copy of each named log, here — the repo's
existing evidence shape (`docs/evidence/issue-990/`, `…/issue-920/`).

| Log (`.log.gz`) | Command | What it covers |
|---|---|---|
| `just-list.log` | `just --list` | the canonical gate entry point |
| `just-fast-01.log` | `just fast` | anti-slop + `core` (1495 tests) + `watch-core` + `health-core` |
| `core-focused-0*.log` | `swift test --filter …` | focused Core suites (focused-01 had a missing `import GRDB` in the new test; 02 fixed it and is the first green focused run; 03 is the post-RED-probe re-run) |
| `red-probe-deadlock.log` | `swift test --filter ForceRecoveryActionPolicyTests` **with the pre-fix rule re-introduced** | RED probe: the deadlock policy fails the new pin (9 failures, `EXIT=1`) |
| `red-probe-flag-leak.log` | `swift test --filter GuidedLaunchLifecycleTests` **with `settle` leaking the timeout flag** | RED probe: the leak fails the lifecycle pin (2 failures, `EXIT=1`) |
| `red-probe-silent-drop.log` | `swift test --filter LocalCacheRepairTests` **with the silent `try?` skip restored** | RED probe: the silent drop fails the repair pin (14 failures, `EXIT=1`) |
| `gen-01.log` | `just gen` | regenerated the Xcode project (new files are in it) |
| `check-watch-project-01.log` | `just check-watch-project` | generated phone + Watch ownership |
| `build-ios-just-01.log` | `just build-ios` (the brief's command) | **`EXIT=74`** — this host's Xcode DerivedData is pinned to the unattached `/Volumes/NVMe2TB` (permission error), a host sequencing issue, not a code failure |
| `build-ios-local-dp-01.log` / `-02.log` | the same `xcodebuild` with a worktree-local `-derivedDataPath` | `01` = `EXIT=65` (one real compile error: a leftover `guidedLaunchInFlight` in the launch guard — fixed); `02` = `** BUILD SUCCEEDED **`, `EXIT=0` |
| `app-tests-0*.log` | `xcodebuild test … -only-testing:SendmeterNativeTests -destination id=0E127B96-… CODE_SIGNING_ALLOWED=NO` | the app-target suite. `03` exposed two lane test bugs (fixed); `04` = the first full run (168 tests); `05`/`06` = my class only; `07` = the second full run in the same container, which hits the **documented one-run-per-container stale-state flake** (`GuidedProtocolCompletionTests.test941BackToBackProtocolsLogOneEntryWhenTheSessionEndsExplicitly`); `08` = the full suite on an **erased** sim — the citable run |
| `docs-check-01.log` | `just docs-check` | stale-command check |

`test-command \| grep` was never used as PASS/FAIL evidence: each command was
run to completion, its exit status captured, and only then was the log read.

## The two rendered frames (PNG, 402×874 pt @3×, real components)

Both were captured by `GuidedLaunchRecoveryAppTests.testCaptureRecoveryAffordanceFrames`
from a hosted `UIWindow` on the simulator's own scene (the same capture
discipline as the #920/#923 evidence test), written into the app container and
copied out of the simulator device directory:

- `settings-local-data-repair.png` — the REAL `SettingsView`, scrolled to its
  sync section, showing the repair notice produced by the fixture's unreadable
  stored row and the "Repair local data" affordance with its unsynced-data
  guarantee.
- `guided-launch-failure-card.png` — the REAL `GuidedLaunchFailureCard`
  (internal so this test could capture it) framed on the grouped background the
  Force tab renders it on: the reason plus **Try Again**.

These are simulator renders, not device screenshots.

## Device-only (NOT claimed anywhere in this lane)

- Real BLE / Tindeq Progressor behaviour, the disconnect salvage on real
  hardware, HealthKit, code signing, TestFlight, and the owner's acceptance of
  the fix on the device.
- The device-log capture that would name the failing launch step (issue half 3)
  — unavailable on this host (see `.report-1004.md` §3).
