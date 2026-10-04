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

## FIX ROUND 1 (hosted-CI red at `c3b72591`) — added logs, same conventions

The round-1 fence failed the hosted app-target job (run 37179622828: attempt 1 = 171 tests /
5 failures, two of them this lane's; attempt 2 = 171 / 3, all the pre-existing
`GuidedLaunchRecoveryAppTests` class). The fix (the fence's determinism seam in
`Tests/SendmeterNativeTests/ForceLockOrphanAppTests.swift`; product code byte-unchanged) and
its verification are described in `.report-1004b-fix1.md`; the logs it rests on:

| Log (`.log.gz`) | Command / run | What it covers |
|---|---|---|
| `hosted-ci-attempt-1-failures.log` | full job logs via `gh api …/runs/37179622828/attempts/1/logs` (read-only) | **171 tests, 5 failures** — the fence's `:297` 15s timeout + `:86` cascade, and the three pre-existing `GuidedLaunchRecoveryAppTests` `:115/:116/:117` lines, verbatim |
| `hosted-ci-attempt-2-failures.log` | …`/attempts/2/logs` | **171 tests, 3 failures** — only the pre-existing class; the fence passed on this attempt; lines verbatim |
| `hosted-ci-run-37187109467-at-0576887.log` | job log via `gh api …/jobs/111391303567/logs` (read-only) — the job that ran the **fix-round head** `0576887` | **this lane's class green on the runner (3/3, no waits)**; the job's only failing tests are the pre-existing `GuidedLaunchRecoveryAppTests` class `:115/:116/:117` (#989); also captures the still-present `step=cache-prepare … cacheUnavailable` runner line the fence now handles deterministically |
| `app-tests-04-repro-dirty.log` | full suite, dirty container, pre-fix | `EXIT=65` — the pre-existing stale-container class in a sibling suite (3 × `test941…`); this lane's class 3/3 green |
| `app-tests-05-fixed-focused.log` | focused, dirty, v1 fix | `EXIT=0`; 3/0 |
| `red-probe-m5-release-touches-recording.log` | **M5**: `ForceView.teardown()` mutated to delete the newest recording in the released session's settlement | `EXIT=65`; 2 failures — the fence detects a data-touching release; `ForceView.swift` restored byte-exact (`sha256 d8d47ee1…`) |
| `app-tests-05b-focused-post-restore.log` | focused, dirty, after the byte-exact restore | `EXIT=0`; 3/0 |
| `app-tests-06-dirty-full.log` | full suite, dirty, v1 | `EXIT=65` — sibling `test941…` ×3 + one `AccountSwitchInFlightAppTests` case aborted by a test-process crash under shared-sim contention; this lane's class 3/3 green; legacy test green |
| `ab-legacy-isolated.log` | `GuidedLaunchRecoveryAppTests.testALegacyStoredPayload…` run **isolated** (A/B arm) | `EXIT=0`; 1/0 — the neighbour-correlation dismissal's second arm (§6 of the fix report) |
| `app-tests-07-erased-full.log` | full suite, **erased** container, v1 | `EXIT=65` — this lane's fence `:133`/`:178` `recordings=[]`: the CI symptom **reproduced locally**; drove the final fix (stage 2 in §3/§4 of the fix report) |
| `app-tests-08-fixed-erased-focused.log` | focused, **erased**, final fix | `EXIT=0`; 3/0 |
| `app-tests-09-fixed-dirty-focused.log` | focused, dirty, final fix | `EXIT=0`; 3/0 |
| `app-tests-10-final-dirty-full.log` | full suite, dirty, final fix | `** TEST SUCCEEDED **`, `EXIT=0` — **171 tests, 0 failures** |
| `app-tests-11-final-erased-full.log` | full suite, **erased** (the hosted job's own shape), final fix | `** TEST SUCCEEDED **`, `EXIT=0` — **171 tests, 0 failures** |
| `core-focused-05.log` | `swift test --filter ForceLockOrphan` at the final tree | `EXIT=0`; 12 tests / 0 failures |
| `slop-fix1.log` / `docscheck-fix1.log` | `just slop` / `just docs-check` at the final tree | `EXIT=0` both |

`SHA256SUMS` above pins every `.log.gz` and the PNG; `shasum -a 256 -c SHA256SUMS` verifies
the whole set.
