# Issue #1015 — app-target flake class #989 did not cover

Branch `impl-1015`, cut from `origin/staging` @ `48788ef`. This is a test-only change. No
production file is touched; every mutation probe below was reverted, and each revert
was checked with an empty `git diff -- native/SendmeterNative/Sources`.

The `.gitignore` excludes `logs/` and `*.log`, so every log is committed here
gzip-compressed and FLAT, as `docs/evidence/issue-1015/<name>.log.gz` (the
raw `logs/` dir stays local). `exits.tsv` is the run ledger. Its columns are
name, head, start, exit, action, and the `Executed …` line. Each log's first line
records `head=<sha> dirty=<0|1>`.

Every run used one reused simulator, `impl1015-sim` (`8B70F6C0-4F65-4D2B-A0E1-101E5AC32993`,
iPhone, iOS 26), which was never erased. That keeps the RED "stale container"
condition and the GREEN "survives a dirty container" condition both real.
Commands are `xcodebuild test|test-without-building -project native/SendmeterNative/SendmeterNative.xcodeproj
-scheme SendmeterNative -destination id=<udid> -derivedDataPath <dd> CODE_SIGNING_ALLOWED=NO <args>`.
The exact command is line 2 (`# cmd:`) of every log.

## What the offenders share

Hosted CI showed rotating reds (receipts in `ci/`):

| Job | Test | Failure |
|---|---|---|
| 111464153739 | AccountSwitch | :379, 1 != 0 |
| 111464323010 | Tindeq | :54/:55/:60, 30 != 61, "1 recording · FDP", 1 != 3 |
| 111484058121 | Phase | :549, 60 s timeout |

Every app-target harness builds a real `AppModel` over a URLProtocol fake. It then
returned as soon as `currentUserID` was set, which is mid-bootstrap. So each test
started inside the app's own launch pass:

- (a) a fixed account carried earlier runs' rows in the ONE app container (the
  pending-write queue is one `pending-writes.json` for every account);
- (b) a wall-clock race between an assertion and an async republish;
- (c) the launch pass (bootstrap `refreshAll`, its drain, and its persisted
  `DurableQueue` store) overlapping the test, in-test and across tests.

  Models are never released, because `authObservationTask` holds a strong
  reference. A previous test's model can still persist a stale store or hit the
  static fake.

The shared fix is `AppModelLaunchSettle.swift`, a test helper:

- `settle(model)` presents the splash with no floor left. Then, on a wall-clock deadline (90 s), it waits
  until the bootstrap has published `.signedIn` with no load or refresh in flight (`isSettled`). An
  expiry fails the test with the observed state.
- `waitForAccount(model)` replaces the `Task.yield()` budgets with a deadline.
- `realtimeOptions` gives one realtime join attempt with a 0.5 s timeout. Without
  it, the realtime join to the fixtures' unresolvable host cost 16–33 s per model
  (see `green-phase-iter20-STOPPED-AT-HEAD-3dd03d2`).

Assertions are unchanged everywhere. Only waits, fixture identities and fixture
ordering moved.

## Per-offender table

The RED / GREEN / mutation cells give the command, the raw exit, and the log path
under `docs/evidence/issue-1015/`.

| # | Offender | Channel | Fix | RED (cmd → exit) | GREEN (cmd → exit) | Mutation (cmd → exit) |
|---|---|---|---|---|---|---|
| 1 | `AccountSwitchInFlightAppTests` (:379) | (b) wall-clock race. Both accounts are fresh per harness, so this is not account coupling. `waitForQuietLog` proves only that the transport went idle; the count republishes later, after upload handling, queue removal/persist and `refreshQueueCount`. | Deadline `waitUntil { queuedWriteCount == 0 }` before the unchanged :379 assertion (now :390). | CI job 111464153739: `:379 XCTAssertEqual failed: ("1") is not equal to ("0")` (`ci/job-111464153739-receipt.txt`). Local base: not reproduced (`base-offenders-run1` → 0). | `green-offenders-iter3` (5 offender classes, `-test-iterations 3`) at `ff84ad9` → **0**, `Executed 99 tests, with 0 failures` | **M1** upload keeps its item (`if shouldRemoveUploadedItem && false`), `-only-testing:…/AccountSwitchInFlightAppTests/testAnAOwnedMutationCompletionNeverEntersTheNewAccountsContext` → **65** (2 failures: the deadline wait expires, then :390 `1 != 0`). `mut-M1-upload-keeps-item.log.gz` |
| 2 | `HealthWriteRecoveryAppTests` | (c) overlap, plus a raw file read with no wait. Each live model owns a `DurableQueue` over the one shared `pending-writes.json`, and `transact` persists before it publishes, so the file can lag the in-memory count. | `queueFileContents(containingAll:)` gives a deadline-bounded file read before each `.contains`. The model is settled. The server stays down across the simulated process death (the settled relaunch's drain no longer replays the intent before the survival assertion). The residue test settles at the END, because its premise is the launch window. | Base `base-health-iter100` → stopped by the lane at 144 passes / 0 failures (`base-health-iter100-STOPPED.log.gz`); **not reproduced locally**. Evidence of the shared-file channel: `container-queue-snapshot-after-base.txt`. | `green-offenders-iter3` at `ff84ad9` → **0** (HWR 27/27 inside the 99) | **M2** queue never persists (`persist` returns early), `…/HealthWriteRecoveryAppTests/testInterruptedHealthWriteIsDurableBeforeItsRowAndReplaysAfterRelaunch` → **65** (5 failures: :70, :86, :97, :102 …). `mut-M2-queue-never-persists.log.gz` |
| 3 | `ForceLockOrphanAppTests` | (a) fixed account `94000000-0000-0000-0000-000000000940`. The reused container still held that account's un-synced recording row from earlier runs (`container-queue-snapshot-after-base.txt`, item `A917218D…`). | A per-test `UUID()` account; `makeSession(userID:)` has no default. Offline stub set before the model exists (the awaited bootstrap failure is then guaranteed; the accumulated queue used to slow the bootstrap enough to hide this). | `container-queue-snapshot-after-base.txt`, after the base runs at `48788ef`: account `…0940` holds a leftover `recording` queue item that the next run inherits. Base run → 0 (`base-offenders-run1`); the coupling shows as state, not a red. | `green-offenders-iter3` at `ff84ad9` → **0** (FL 9/9) | **M3** force save never enqueues, `…/ForceLockOrphanAppTests/testTheReleaseOverAnEndedSessionLeavesThePendingRowUntouched` → **65** (2 failures: :133, :147). `mut-M3-force-save-no-enqueue.log.gz` |
| 4 | `TindeqSessionMergeAppTests.testMergeFoldsThreeSameDay…` (:54/:55/:60) | (c) overlap. The fixed session, group and recording ids were shared by every test and run, and a merge's queue item id IS its survivor's session id. | Fresh per-test ids, generated ascending (`ascendingIDs`): rows share one `updated_at`, so the delta reader orders by id and fails closed on an unsorted page. The fake now honours the delta cursor's `id.gt` arm like PostgREST; it used to re-serve every row, so the settled second read failed closed (`outOfOrderPage`). Deadline `waitForQueueCount`; settle. | CI job 111464323010: `:54 30 != 61`, `:55 "1 recording · FDP"`, `:60 1 != 3` (`ci/job-111464323010-receipt.txt`). Local base: not reproduced (`base-offenders-run1` → 0). | `green-offenders-iter3` at `ff84ad9` → **0** (Tindeq 9/9) | **M4** merge keeps the old groups (`recordings[index].groupID = plan.groupID` dropped), `…/TindeqSessionMergeAppTests/testMergeFoldsThreeSameDayEntriesIntoOneAndKeepsEveryRecording` → **65** (1 failure: :81 `1 != 3`). `mut-M4-merge-keeps-groups.log.gz` |
| 5 | `PhaseTransitionReplayAppTests.testLostSettingsHalf…` (:549 timeout) | (c) overlap. The bootstrap `refreshAll` publishes during the test's await, and an un-settled previous model's tail persists into the shared queue file. The exact interleaving is inferred, not proven. | `settle` in `makeSignedInModel`. The residue test (`testLegacyPhaseResidues…`) opts out (`settleBootstrap: false`) and settles at its end, because its premise is "visible before the sweep". | Base `base-phase-iter50` (`-test-iterations 50 -run-tests-until-failure`) at `48788ef` → **65**: at iteration 12, `testOlderTransitionCompletionCannotClearANewerLocalBlock` timed out at :549 (same helper, same 60 s shape), then :322/:327/:328. CI job 111484058121 for `testLostSettingsHalf…` (`ci/job-111484058121-receipt.txt`). | `green-phase-iter20` (`-test-iterations 20 -run-tests-until-failure`) at `98e53f8` → **0**, `Executed 180 tests, with 0 failures`; plus `green-offenders-iter3` at `ff84ad9` → **0** (PTR 27/27) | **M5** the lost settings half is never completed (the `updateSettings` call is skipped), `…/PhaseTransitionReplayAppTests/testLostSettingsHalfIsCompletedFromTheServerState` → **65** (3 failures: :556 timeout, :269, :270). `mut-M5-settings-half-skipped.log.gz` |

Mutation mechanics:

- Each probe is a single production edit, recorded as `mutation-<id>.diff.gz`.
- It is built into a separate DerivedData (`impl1015-derived-mut`).
- The target test runs, then the file is restored with `git checkout`.
- The probe then asserts that `git diff --quiet -- native/SendmeterNative/Sources` holds.

The receipts are `mutation-revert-receipts.txt` (`sources-clean-after-<id>=0` × 5). Each
mutation leg's log carries `dirty=1` (the mutation itself); the legs' head is
`af72467`, and their build logs are `mut-*-build` in `exits.tsv`.

## Repeat stability (full suite × 3, final head)

`-only-testing:SendmeterNativeTests`, `test-without-building` after one `build-for-testing`
(`full-build-2` → 0), at head `63e4924`:

| Run | Head | Exit | Result | Log |
|---|---|---|---|---|
| `full-run1` | `63e4924` (dirty=0) | **0** | `Executed 184 tests, with 0 failures (0 unexpected) in 350.205 (350.316) seconds` | `full-run1.log.gz` |
| `full-run2` | `63e4924` (dirty=0) | 65 | **0 tests executed**: `Sendmeter (31185) encountered an error (The test runner hung before establishing connection.)`, so the runner never started | `full-run2-RUNNER-HUNG.log.gz` |
| `full-run3` | `63e4924` (dirty=0) | **0** | `Executed 184 tests, with 0 failures (0 unexpected) in 344.596 (344.656) seconds` | `full-run3.log.gz` |
| `full-run4` | `63e4924` (dirty=0) | 65 | **0 tests executed**: the same runner-hung error; the host was loaded by another lane's simulators | `full-run4-RUNNER-HUNG.log.gz` |
| `full-run5` | `63e4924` (dirty=0) | **0** | `Executed 184 tests, with 0 failures (0 unexpected) in 347.410 (347.504) seconds` | `full-run5.log.gz` |

The suite passed three times with no test failure across all five runs. Runs 2 and 4 are test-runner
launch failures with zero tests executed: an infrastructure failure, not a test result. They
are kept and labelled, not deleted. Every commit after `63e4924` is docs/evidence only:
`git diff 63e4924..HEAD -- native` is empty.

## Gates (raw exits)

| Gate | Exit | Log / note |
|---|---|---|
| `just slop` | **0** | `gates-just-slop.log.gz`: "Anti-slop config, wrapper, source path, and advisory CI wiring passed" |
| `just core` | **0** | `gates-just-core.log.gz`: `Executed 1535 tests, with 0 failures` (host SwiftPM) |
| `just check-static` | **1** | `gates-just-check-static.log.gz`: "Generated project is missing the Force source: ManualForceFullscreen.swift". **The base fails the same way:** `just check-static` on a `git archive 48788ef` tree → **1** with the identical line (`gates-base-48788ef-just-check-static.log.gz`). The script still lists a file #906 removed; it lives in `scripts/`, outside this lane's fence, so it is a follow-up |
| `git diff --check origin/staging..HEAD` | see the final report | Run on the final head |
| `just gen` | 0 | `gates-just-gen*.log.gz`; no project.yml change; the `.xcodeproj` stays untracked |

A stale log name in a source comment: `AppModelLaunchSettle.swift` cites
`green-phase-iter20-STOPPED.log`. The committed file is `green-phase-iter20-STOPPED-AT-HEAD-3dd03d2.log.gz`.
The comment was left alone so the full ×3 tree stayed frozen.

## Sweep (item 6) — other `*AppTests`

Smell 1 is a fixed shared account UUID. Smell 2 is an assertion on a published or durable value straight after an `await`, with no deadline.

| Suite | Finding | Action |
|---|---|---|
| `DirectWriteReplayAppTests`, `PersistedFailureLogAppTests`, `TagMutationReplayAppTests`, `ZoneCurvePopulationAppTests` | `while currentUserID == nil, waited < 200 { Task.yield() }`: a yield-count budget, not a deadline | Replaced by `AppModelLaunchSettle.waitForAccount(model)`, same condition and same `XCTAssertNotNil` after it |
| `DashboardLoadFailureAppTests`, `SyncSurfacesAppTests` | Same yield budget (200 / 400) | **Converted, then reverted to base byte-for-byte** (`63e4924`). See below. **Follow-up.** |
| `CoherentCacheReadAppTests` | Has its own sleep loop and its own settle | Unchanged |
| `ReadinessWidgetAppTests` (`2222…`) | A fixed id, but a UserDefaults suite with no app container or queue | Unchanged (not this channel) |
| `WatchReadinessDispatchAppTests` (`…00C3`) | A fixed id, with no `AppModel` and no container | Unchanged (not this channel) |

The two reverted suites: `full-run1` at `50caf2b` → **65**, `Executed 184 tests, with 7 failures`
(`full-run1-AT-HEAD-50caf2b.log.gz`). All 7 failures were in those two suites:

- DashboardLoadFailure :57/:58/:65
- SyncSurfaces :402/:403 and :421/:422

They assert the state of an explicit `refreshAll` (e.g. "the load never published
data"). At base they pass only because the harness returns while the bootstrap pass
is still pending. Waiting for the account longer lets that pass publish first.
That is the same channel (c) overlap. The fix those suites need is a settle-and-
re-arm of their fakes, not a longer wait. That is beyond a mechanical sweep, so they
stay at base and are listed as a follow-up.

## Production finding (item 7) — severity: diagnostic loss only

The race is a concurrent refresh tombstone blanking an undecodable row before launch repair quarantines it. Its worst case loses the **diagnostic copy of an already-undecodable,
non-pending, server-origin row**. It loses no user data. Evidence comes from reading the three seams:

- `CachedWorkspace.reconcileServerDelta` (CachedWorkspace.swift ~481–493) skips pending ids.
- `LocalCacheStore.markDeletedDeltaServer` (LocalCacheStore.swift ~1266–1285), and `upsertDeltaServer` (~1192+), keep
  the payload and `deleted_at` when `pending = 1 AND write_origin = 'local'`. A local un-synced row is never
  blanked.
- `LocalCacheRepair.quarantineInvalidRows` (LocalCacheRepair.swift ~136–153) only considers `deleted_at IS NULL`
  and non-pending rows.

So the only row the race can blank is a non-pending, server-origin row that is **absent from the server's
own full snapshot**. The server already says it is gone. If the server still carries it, the upsert replaces
the payload and the row is rebuilt. What is lost is the raw bytes in `cache_quarantine`, the Settings repair
notice and the log line.

Existing tests already pin the user-data half:

- `CachedWorkspaceTests:1044` `testPendingRowSurvivesAuthoritativeDeltaTombstone`
- `CachedWorkspaceTests:1172` `testDeltaFullReconcilePreservesPendingRowsAbsentFromSnapshot`
- `WorkspaceSyncCoordinatorTests:598` `testAFullReconcileKeepsAPendingLocalRowTheServerDidNotCarry`

There is no production change. The recommended follow-up is to serialize launch repair before the first reconcile.

## Follow-ups (not filed — the orchestrator files)

1. `DashboardLoadFailureAppTests` / `SyncSurfacesAppTests`: the same launch-window overlap, needing a settle plus fake re-arm
   (see Sweep).
2. Item 7: serialize `LocalCacheRepair` before the first delta reconcile.
3. Production hypothesis, **unverified**: `PhaseTransitionIntent.queueItemID` is fixed across accounts, and
   `enqueueIfCurrent` matches on id only. A pending transition for account A could then block account B's from queueing.
4. `scripts/validate-native-static.sh` still requires `ManualForceFullscreen.swift` (removed in #906); red at base.
5. CI cost: until `realtimeOptions`, every app-target model paid a 16–33 s realtime join. Other app-target
   harnesses that never settle still start that join (they don't wait on it).

## Run history, disclosed (nothing deleted)

- `base-health-iter100` was **stopped by the lane** at 144/0, before the orchestrator's "do not stop the queue"
  message was read (`base-health-iter100-STOPPED.log.gz`).
- At `168422d` the lane **killed** the first GREEN queue: `green-phase-iter50` showed the residue test failing
  `:394 2 != 5`, because the start settle let the bootstrap sweep the seeded residue. Fixed in `3dd03d2`
  (`*-STOPPED-AT-HEAD-168422d.log.gz`).
- `green-phase-iter20` at `3dd03d2` was 130 passed / 0 failed when **stopped by the lane** for cost (16–33 s per
  test). Fixed in `98e53f8` (`realtimeOptions`) (`green-phase-iter20-STOPPED-AT-HEAD-3dd03d2.log.gz`).
- `green-offenders-iter3` at `98e53f8` had 78 passed / 4 failed when **stopped by the lane**:
  - Health :78 failed 3/3. The settled relaunch drain replayed the intent.
  - ForceLock :367 failed 1/3. The offline stub was set after the model.

  Fixed in `28081a4` (`green-offenders-iter3-STOPPED-AT-HEAD-98e53f8.log.gz`).
- `green-offenders-iter3` at `28081a4` → **65**, 99 tests / 42 failures, all of them Tindeq. The fresh random ids
  broke the delta page order (`outOfOrderPage`). The other four classes passed 90/90
  (`green-offenders-iter3-AT-HEAD-28081a4.log.gz`).

  `d58384f` (ascending ids) was necessary but not sufficient. `green-tindeq-iter5` at `d58384f` still had 0
  sessions (`green-tindeq-iter5-AT-HEAD-d58384f.log.gz`, stopped). `ff84ad9` makes the fake honour the cursor.
  `green-tindeq-iter5-probe` → **0**, 15 tests / 0 failures. That probe ran on the ff84ad9 tree before it was
  committed, so its ledger head reads `d58384f` with `dirty=1`.
- `full-run1` at `50caf2b` → **65** (the sweep finding above). `full-run2` at `50caf2b` was stopped before any test.
- At `63e4924`, `full-run2` and `full-run4` → 65 with the runner hung before connecting (0 tests); see Repeat stability.
