# Host gate failures: hanging suites, runner launch failures, and the retry policy

Measured 2026-09-19 on the fleets' Mac (macOS 26.6.2, Xcode 26.6, 10 CPUs) while diagnosing
[#956](https://github.com/jirathip-dev/sendmeter/issues/956). Raw evidence:
`docs/evidence/issue-956/`; the lane report (with the attribution table) is `.report-1.md`.

Four consecutive lanes (`impl-914`, `impl-915`, `impl-918`, `impl-919`) lost hours to these
behaviours and misread two of them as test verdicts. Nothing here weakens a test: a hang is
infrastructure evidence, never a pass and never a fail.

## The three classes you will actually meet

| Signature (what the log shows) | Class | What it is | What to do |
| --- | --- | --- | --- |
| `swift test` / `just fast` / `just core` stops printing; the test process idles at 0 % CPU for minutes | **Test-side idle hang** — not the host, not SwiftPM | An `async` XCTest test whose `await` never resumes (the suite's own continuation gate can leak; see "The #956 finding") | Bound the wait, `sample` the test process, keep the log + the sample, **retry once**, and treat it as an issue-956 data point. Never weaken or skip the test |
| `The test runner hung before establishing connection.`, `Executed 0 tests`, exit 65 (simulator suites) | **Simulator/runner launch infra** | The XCTest runner never attached to the simulator (measured locally too: app launched, idle, 0 tests) | `xcrun simctl shutdown/erase/boot` **your own** lane simulator, then retry the same command once |
| `queue never reached <N>; last observed <M>` in an app-target suite | **Slow-runner timing against a fixed wait budget**, and/or **stale app container** | The harness polls a bounded number of times (e.g. 600 × 5 ms ≈ 3 s); a run that is ~60 % slower can expire it, and a container that already holds the row makes the write look already-applied | See "The app-target suite" below: erase per recorded run, and treat the wait budget as host-speed-dependent |
| `just build-ios` exits 74 before compiling, or blocks inside `mkdirat` on `/Volumes/NVMe2TB` | **Pinned DerivedData (host config)** | Xcode's DerivedData location points at the unattached `/Volumes/NVMe2TB` | Build with a worktree-local `-derivedDataPath` and report both runs. Never change host settings |

An honest fourth outcome exists: when no measurement supports a class, write
`UNATTRIBUTED` and name the exact missing measurement (which counter, which sample, which
reproduction). An unanswered observation is a valid result.

## The buffered-log trap: "it hung at test X" is usually wrong

`swift test` pipes the test runner's stdout, so the runner's `stdout` is **block-buffered**.
The last line in your log can be tens of test lines *behind* where the process stopped — it
usually ends mid-line, which is a flush boundary, not the hang point.

Measured at `b2c4df42`, same suite, both ways:

- default buffering: `…GuidedForceFullscreenPresentationTests testSingleSideSelectionNamesTheSideTheRestHandsOffTo]' passed`
  then a truncated `Test Case '-[SendmeterCor` — **not** where the process stopped;
- `NSUnbufferedIO=YES swift test …`: the last line is the true last line
  (`…GuidedForceTerminalSettlementTests testConcurrentTerminalCallersJoinOneSettlement]' started.`).

`NSUnbufferedIO=YES` reaches the runner — verified with `ps eww -p <xctest pid>` while the
suite ran. Use it whenever you chase a hang; it costs nothing.

**Second instrument (no env needed):** the hung runner's own argv names the test —
`xctest -XCTest <Class>/<test> <bundle>`. Look for it with
`ps -Ao pid,ppid,pgid,command | grep xctest`.

## The retry policy (measured, not a wish)

Numbers from `docs/evidence/issue-956/` at `b2c4df42` on a quiet host (10-min load average
≤ 8.5, memory-pressure level 1 = normal, 0 `xcodebuild`/`swift-test`/`xctest` processes by
`pgrep -x`):

- `just fast` (the full gate): **3/3 green**, 151 s cold / 46 s / 45 s warm;
- full `swift test` (core suite alone): green in 8 of 9 runs; **the hang fired once at
  1-min load 2.39** — quiet is not protection;
- the hangs are real and intermittent: **6 hangs in 26 lane-tree `swift test` invocations
  (~23 %)**, every one at the same test, and **1 of 6 immediate retries hung again**.

So the correct policy is:

1. **Try the gate once.** A hang on the first attempt is the issue-956 class, not your diff.
2. **Bound it** (watchdog + `sample <pid>`) and kill **your own recorded pids**: the
   `zsh` → `just` → `swift-test` chain *and* the runner. SwiftPM puts the `xctest` runner in
   its **own process group**, so a group kill on the driver orphans it — three orphaned
   runners were found this way (PPID 1, 0.0 % CPU). Clean up with
   `pgrep -x xctest` + a match on your worktree path in the argv.
3. **Retry once.** A green retry is a legitimate full-gate result *as long as both attempts
   are reported* with their raw exits (the first attempt's 143 and the retry's 0 both belong
   in the report). A retry is not guaranteed: at this head one of six retries hung again.
4. **When the retry hangs too**, stop retrying and cover the same content with the individual
   recipes (`just slop`, `just core`, `just watch-core`, `just health-core`) plus focused
   `--filter` runs, and say in your report that the full-gate shape was covered by components.

A retry-once policy covers host/launch noise and gets you a reportable green run. It does
**not** cover the underlying race (it hides it), which is why the finding below is filed.

## The #956 finding (test-side race, open)

`GuidedForceTerminalSettlementTests.testConcurrentTerminalCallersJoinOneSettlement`
(`native/SendmeterNative/Tests/SendmeterCoreTests/GuidedForceFullscreenPresentationTests.swift`,
the `Gate` helper, `:551-568`) leaks a `CheckedContinuation`: `wait()` checks `isOpen` and
then appends **without synchronization**, while `open()` — running on the other executor,
because the operation is `@MainActor` and the test body is not — can drain the waiter list
in between. `await first.value` then never resumes, XCTest's async waiter never returns,
and the runner idles at 0 % CPU.

Tells to look for in a log of this class:

- `SWIFT TASK CONTINUATION MISUSE: wait() leaked its continuation without resuming it.`
  (runtime message; seen live at this head), and
- the runner's main thread parked in XCTest's `waitForExpectations` run-loop wait with no
  Sendmeter frame on any thread (`hung-runner-sample.txt.gz` in the evidence dir).

A race-free replacement for that helper, and the RED/GREEN measurement of it, are in
`.report-1.md` and `docs/evidence/issue-956/`. It is a **test-file** change, so it is routed
by the orchestrator rather than applied from the diagnosis lane.

## The app-target suite: one run per container, and a wait budget that assumes a fast runner

The app-target suite writes real state into the installed app's container
(`pending-writes.json`, `local-cache.sqlite`) and several tests share fixed account ids, so a
container that already holds a row makes an offline write look already-applied and the
intent is never enqueued — the assertion then fails as
`queue never reached <N>; last observed <M>`. Committed precedent:
`docs/evidence/issue-926/apptests-attempt2-stale-container.log.gz` (attempt 2 on a stale
container fails in exactly that way; green again after an erase).

The **same message** is also produced by a slow runner, measured on hosted CI
(PR #969, `iOS Simulator build`, `PhaseTransitionReplayAppTests:519`): the passing neighbour
run executed the same 117 tests `in 33.370 (33.425) seconds` with the test `passed (1.180 s)`,
while both failing runs took `54.406 (58.053)` / `54.858 (59.939)` seconds with the test
`failed (4.370 s)`. The harness's wait is a fixed 600 × 5 ms ≈ 3 s poll, so a ~60 % slower
run can expire it. Keep the assertion; treat the wait budget as host-speed-dependent
(the recommended fix is a generous wall-clock deadline or an event-based wait — never a
weaker expectation).

Rules:

- **One recorded run per container.** After a recorded app-target run, `xcrun simctl erase`
  your own simulator (or create a fresh one) before the next recorded run.
- **Never** read a second run's failures in the same container as product verdicts.
- A failed `iOS Simulator build` job may spend a further **~10 minutes** *after* the tests in
  `xcodebuild`'s diagnostics collection (`Failure collecting diagnostics from simulator:
  Timed out after 600.0 seconds`) — a separate post-failure mechanism, not part of the test
  failure. Budget for it when judging "the job took 15+ minutes".

## Host contention has a shape on this Mac: simulator boot storms

Measured here while bringing up one iOS simulator (erase + boot, and again for the per-run
erase cycle): **up to 467 `CoreSimulator` processes and a 1-min load average of ~235 on
10 CPUs**, decaying within a few minutes; memory pressure stayed at level 1. That is the same
order the fleet reports as "sibling fleets drive the host to load 100–235". If your gate is a
simulator gate, expect the boot storm — and give it time to settle before you measure
anything, because it is contention *from the tooling itself*, not evidence about your diff.
