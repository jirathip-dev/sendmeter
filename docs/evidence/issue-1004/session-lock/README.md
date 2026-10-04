# Evidence — sendmeter issue #1004 (session-lock layer), lane `impl-1004-lock`

Everything here was produced in THIS lane's worktree
(`/Users/jirathip/.herdr/worktrees/sendmeter/impl-1004-lock`) at the head named in
`.report-1004b.md`. Nothing here is device evidence; the device-only items are listed at the
bottom.

## The named logs, one per command, each ending with the raw `EXIT=<code>`

The lane wrote every command's output to a named log under
`docs/evidence/issue-1004/session-lock/logs/` while working (that plaintext set is still on
the machine). The repo's `.gitignore` ignores any `logs/` directory, so the COMMITTED
evidence is the gzipped copy of each named log, here — the same shape as
`docs/evidence/issue-1004/` (the issue's first half).

| Log (`.log.gz`) | Command | What it covers |
|---|---|---|
| `just-list.log` | `just --list` | the canonical recipe list |
| `slop-01.log` | `just slop` | anti-slop gate, green after the committed slice `ce18842` |
| `slop-02.log` | `just slop` | anti-slop gate on the FINAL tree (all files of this lane) |
| `just-core-01-aborted-disk-full.log` | `just core` | **`EXIT=1`** — aborted by the 11:38 host disk-full (the session-DB incident named in the brief's addendum), not a code failure; kept as history |
| `just-core-02.log` | `just core` | the PRIMARY gate at this head: **`EXIT=0` — 1507 tests, 0 failures (0 unexpected)** in 230s |
| `swiftc-parse-01.log` / `-02.log` | `xcrun swiftc -parse <each changed file>` | cheap syntax pre-check before xcodebuild (02 = final tree) |
| `gen-01.log` | `just gen` | regenerated the Xcode project (new files included) |
| `check-watch-project-01.log` | `just check-watch-project` | generated phone + Watch ownership |
| `check-static-01.log` | `just check-static` | **`EXIT=1`, proven pre-existing**: the script's hardcoded Force-source list still names `ManualForceFullscreen.swift`, which `fe860c6` (#899) deleted — absent at `origin/staging` too; `project.yml` unmodified; both script invariants hold. Its parse phase (all 345 native files) passed. Proof appended in the log. |
| `docs-check-01.log` | `just docs-check` | stale-command check |
| `core-focused-0{1,2,3,4}.log` | `swift test --filter ForceLockOrphan*` | focused Core suites (01 = first run, before a test-harness fix; 02 = first green, 12 tests 0 failures; 03 = re-green after M1–M3; 04 = re-green after M4) |
| `red-probe-01-orphan-branch.log` | `swift test --filter ForceLockOrphan` **with `owner()` always returning `.resumableSession`** | RED: 5 failures, `EXIT=1` |
| `red-probe-02-requires-release.log` | …**with `requiresRelease` inverted** | RED: 6 failures, `EXIT=1` |
| `red-probe-03-release-gate.log` | Core wiring suite **with `if guidedLockOrphaned` inverted** | RED: 4 failures, `EXIT=1`; ForceView restored byte-exact (`shasum`) |
| `red-probe-04-static-fence.log` | Core wiring suite **with a `"queue"` token inserted into the release body** | RED: 1 failure exactly (`testTheReleaseOnlyTouchesAnEndedSessionAndNoDataAtAll`), other 4 pass; restored byte-exact |
| `app-tests-01-focused.log` | the app leg, first attempt on the shared sim (dirty container) | **`EXIT=65`** — this run exposed the stale-container interference described in the report §6; kept as history because it is why the final fence reads the queue in one turn around the release |
| `app-tests-03-full-fresh-sim.log` | `xcodebuild test … -only-testing:SendmeterNativeTests` on the **erased** sim, `CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **`, `EXIT=0` — **171 tests, 0 failures**, including all of `ForceLockOrphanAppTests` (3/3) |
| `candidate-0{1,2,3,4}-*.log` | executed greps/probes | the four §2 candidates: Live Activity, watch ownership, persisted session, cache lease — verdicts in the report |
| `device-log-recheck-01.log` | bounded `log show --archive` + transcript greps | the device-log half: still unavailable (0 subsystem rows; transcript has 0 `launch failure` lines) |
| `section2-anchors.log`, `section2-copy-location.log`, `scope-delta.log` | greps/git | the report's quoted `file:line` anchors, the copy-location search, and the diff scope / MUST-NOT-change verification |

## The rendered frame (PNG, 402×874 pt @3×, the real component)

`guided-session-release-card.png` was captured by
`ForceLockOrphanAppTests.testCaptureReleaseAffordanceFrame` from a hosted `UIWindow` on the
simulator's own scene (the same capture discipline as the #920/#923 and #1004-first-half
evidence tests), written into the app container and copied out of the simulator device
directory. It shows the REAL `GuidedSessionReleaseCard` (internal so this test can capture
it) framed on the grouped background the Force tab renders it on: the heading ("A finished
guided protocol is holding this screen"), the notice that states nothing recorded, queued or
left unsaved is deleted, and the one **Clear Finished Session** button.

This is a simulator render, not a device screenshot.

## Device-only (NOT claimed anywhere in this lane)

- Real BLE / Tindeq Progressor behavior — including the mid-pull interruption that can
  produce the orphan on a real strap — HealthKit, code signing, TestFlight, and the owner's
  acceptance of the release on his phone.
- The device-log capture that would name the failing payload from the owner's unit (issue
  half 3) — still unavailable on this host; the report §4 gives the one command that
  produces it.
