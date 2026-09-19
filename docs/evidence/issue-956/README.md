# issue-956 evidence (host/harness diagnosis, lane impl-956, base b2c4df42)

Read `.report-1.md` (repo root) for the attribution table and the verdicts; this file maps
the artifacts. All sizes are gzipped originals; `hashes.txt` carries the sha256 of each file.

## Reproductions at this head

| File | What it is |
| --- | --- |
| `host-state-ledger.txt.gz` | per-run host state (load, memory-pressure level, free memory, disk, `pgrep` of heavy processes) for the three `just fast` runs |
| `just-fast-run1-cold-quiet.log.gz` | `just fast` run 1 (cold `.build`, quiet host) — exit 0, 151 s, 2010 test cases |
| `just-fast-run2-warm-unbuffered.log.gz` | `just fast` run 2 (`NSUnbufferedIO=YES`) — exit 0, 46 s |
| `just-fast-run3-warm-plain.log.gz` | `just fast` run 3 (plain) — exit 0, 45 s |
| `battery-ledger.txt.gz` | the repetition battery results (8 focused + 6 full-suite runs) with per-run load |
| `battery-focus-hang.log.gz`, `battery-focus-hang-stall.txt.gz` | the focused-run hang (H2) and the watchdog's stall dump (note: no child in the driver's process group — the runner has its own, §2.3 of the report) |
| `battery-full-suite-hang.log.gz`, `battery-full-suite-hang-stall.txt.gz` | the full-suite hang (H3) frozen at test #505 and its stall dump |

## Forensics of the hang

| File | What it is |
| --- | --- |
| `hang-forensic-dump.txt.gz` | process tree, driver fds and samples taken while the runner was frozen (H4) |
| `hang-forensic-trace.txt.gz` | the instrumented repro's per-iteration trace (`saw_child=1`) |
| `hung-runner-sample.txt.gz` | **live `sample` of the hung runner** — main thread parked in `XCTWaiter waitForExpectations` → `_synchronouslyWaitForTimeInterval` → CFRunLoop, 1565/1568 samples, no Sendmeter frame |
| `orphan-runners-inventory.txt.gz` | `ps` inventory of the three orphaned runners (PPID 1) whose argv names the hanging test |
| `nsubbufferedio-env-check.txt.gz` | proof that `NSUnbufferedIO=YES` reaches the runner (`ps eww -p <xctest pid>`) |
| `continuation-misuse-hang.log.gz` | the hang that printed `SWIFT TASK CONTINUATION MISUSE: wait() leaked its continuation without resuming it.` |
| `prior-hang-samples-analysis.md` | thread-by-thread analysis of the samples committed by impl-915/917/918/919 |

## Layer-2 (SPM lock)

| File | What it is |
| --- | --- |
| `spm-lock-demo-state.txt.gz` | the first (missed-overlap) lock demo |
| `spm-lock-demo2-state.txt.gz` | the second demo's state |
| `spm-lock-holder2.log.gz`, `spm-lock-second2.log.gz` | the long holder and the blocked second invocation, with the `Another instance of SwiftPM …` line |

## Concurrency leg (another worktree's cold suite alongside the lane)

| File | What it is |
| --- | --- |
| `concurrency-leg-state.txt.gz` | the three lane runs under load + the sibling suite's result |
| `concurrency-scratch-worktree-suite.log.gz` | the sibling worktree's own suite (1344/0, exit 0) |
| `conc-lane-1.log.gz` … `conc-lane-3.log.gz` | the lane runs (run 1 hung under load; run 2 is the self-inflicted exit-1 artifact; run 3 green) |
| `conc-hang-capture.txt.gz` | the live capture of the load-conditioned hang (process table + runner sample + log tail) |

## The `Gate` fix (demonstrated in a scratch clone, NOT applied here)

| File | What it is |
| --- | --- |
| `gate-race-fix.diff` | the patch (one helper, ~9 changed lines; no assertion touched) |
| `fixdemo-ledger.txt.gz` | the RED/GREEN ledger — **both legs 0/12 hangs**, see §5 of the report for why this does not discriminate |
| `fixdemo-red-sample-run.log.gz`, `fixdemo-green-sample-run.log.gz` | one full log from each leg |

## Hosted CI evidence (O3b) + the requested focused battery

| File | What it is |
| --- | --- |
| `hosted-969-attempt1-fail.log.gz` | `gh run view 35455230541 --attempt 1 --log-failed` — the full failed `iOS Simulator build` log: `queue never reached 1; last observed 0` at `PhaseTransitionReplayAppTests.swift:519` (tests 16:36:24→16:36:56, `54.406 (58.053) seconds`) and the post-failure `Timed out after 600.0 seconds` diagnostics collection |
| `hosted-969-attempt2-excerpt.txt.gz` | the re-run at the same SHA — key lines: same test, `failed (3.933 seconds)`, `54.858 (59.939) seconds`, same 600 s tail |
| `hosted-pr967-pass-excerpt.txt.gz` | the passing neighbour (#967, same 117 tests) — `Executed 117 tests, with 0 failures … in 33.370 (33.425) seconds`, the test `passed (1.180 seconds)`: the timing comparison that attributes O3b to a slow runner against the harness's fixed ~3 s poll budget |
| `focused-phase-battery.txt.gz` | the N≥5 local battery of that single test (fresh app container per run) + one full log per run |

## App-target re-measurement (O3)

| File | What it is |
| --- | --- |
| `apptarget-state.txt.gz` | the experiment's state: erased sim, run 1 (fresh container), container dumps, run 2, cleanup |
| `apptarget-run1-fresh-container.log.gz` | full suite on the erased sim — `TEST SUCCEEDED`, `Executed 108 tests, with 0 failures` |
| `apptarget-run2-same-container.log.gz` | the second run — `Testing started` with 0 tests (runner-launch failure class) |
| `apptarget-run2-livestate.txt.gz` | live process/device state at that failure |
| `apptarget-run2-app-sample.txt.gz` | `sample` of the launched-but-idle app process (2 threads, run-loop waits) |

