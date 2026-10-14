## #1015 — app-target flake class #989 did not cover (test-only)

Refs #1015 · follows #989 / #1012

The hosted `iOS Simulator build` job (`-only-testing:SendmeterNativeTests`) kept failing on a rotating
app-target class. CI receipts:

- AccountSwitch :379 (job 111464153739)
- Tindeq :54/:55/:60 (job 111464323010)
- Phase :549 (job 111484058121)

Every app-target harness returned as soon as `currentUserID` was set, which is mid-bootstrap. So each
test started inside the app's own launch pass, in one shared simulator container. Three coupling
channels follow:

- (a) a fixed account inheriting earlier runs' queue rows;
- (b) assertions racing an async republish;
- (c) the launch pass overlapping the test, in-test and across tests. Models are never released, and one
  `pending-writes.json` serves every account.

### Changes (tests only — no production file touched)

- **New `AppModelLaunchSettle`** (test helper):
  - `settle` — wall-clock wait until the bootstrap has published `.signedIn` with nothing in flight;
  - `waitForAccount` — a deadline instead of `Task.yield()` budgets;
  - `realtimeOptions` — one fast-failing realtime join, where the SDK default cost 16–33 s per model.
- **AccountSwitchInFlight** — channel (b). Deadline wait for the republished count before the unchanged
  assertion.
- **HealthWriteRecovery** — channel (c):
  - deadline-bounded file reads before each `.contains`;
  - the model is settled;
  - the server stays down across the simulated process death;
  - the residue test settles at its end.
- **ForceLockOrphan** — channel (a). A per-test account instead of `94000000-…0940`; the offline stub is set
  before the model.
- **TindeqSessionMerge** — channel (c):
  - fresh per-test ids, generated ascending, since rows share one `updated_at` and the delta reader orders
    by id;
  - the fake now honours the delta cursor (`id.gt`) like PostgREST;
  - deadline queue-count wait; settle.
- **PhaseTransitionReplay** — channel (c). Settle; the residue test opts out and settles at its end.
- **Sweep** — `DirectWriteReplay`, `PersistedFailureLog`, `TagMutationReplay` and `ZoneCurvePopulation` move to
  `waitForAccount`.

No assertion was weakened. Only waits, fixture identities and fixture ordering changed.

### Evidence — `docs/evidence/issue-1015/README.md`

The README carries the per-offender table: channel, fix, RED / GREEN / mutation command and raw exit, and
log paths. Highlights:

- RED:
  - base `PhaseTransitionReplayAppTests -test-iterations 50 -run-tests-until-failure` → **65** (:549
    timeout at iteration 12);
  - the three CI receipts;
  - the stale-container queue snapshot (account `…0940` holding a leftover row).
- GREEN:
  - Phase `-test-iterations 20` → **0** (180 / 0);
  - the five offender classes `-test-iterations 3` → **0** (99 / 0).
- Mutation:
  - M1–M5, one production line each → **65** for every hardened test;
  - each reverted, with an empty `Sources` diff verified.
- Full suite at `63e4924` (the final native tree):
  - three runs → **0**, each `Executed 184 tests, with 0 failures`;
  - two runs → 65 with *the test runner hung before establishing connection* (0 tests executed; disclosed).

### Sweep finding — follow-up

`DashboardLoadFailureAppTests` and `SyncSurfacesAppTests` were converted, then reverted to base. Once the
account wait is real, they fail (7 failures): they assert an explicit refresh's state and pass at base only
because the bootstrap pass is still pending. They need a settle plus fake re-arm, which is a follow-up.

### Production finding (issue item 4) — severity: diagnostic loss only

A concurrent refresh tombstone can blank an undecodable row before launch repair quarantines it. That is
possible only for a **non-pending, server-origin row the server's own snapshot no longer carries**:

- `reconcileServerDelta` skips pending ids;
- `markDeletedDeltaServer` / `upsertDeltaServer` keep local pending payloads;
- `quarantineInvalidRows` only takes live, non-pending rows.

What is lost is the quarantine copy, the repair notice and the log line. No user data is lost. Existing proofs:

- `CachedWorkspaceTests:1044`
- `CachedWorkspaceTests:1172`
- `WorkspaceSyncCoordinatorTests:598`

There is no production change. Follow-up: serialize launch repair before the first reconcile.

### Follow-ups (for the orchestrator to file)

1. A settle plus fake re-arm for `DashboardLoadFailureAppTests` / `SyncSurfacesAppTests`.
2. Serialize launch repair before the first reconcile (item 7).
3. `scripts/validate-native-static.sh` still requires `ManualForceFullscreen.swift`, which #906 removed. `just check-static` → 1 at base `48788ef` and here, with the same line.
4. Unverified hypothesis: `PhaseTransitionIntent.queueItemID` is fixed across accounts, and
   `enqueueIfCurrent` matches on id only.
