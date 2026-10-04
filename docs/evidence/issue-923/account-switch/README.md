# Evidence — issue 923, account-switch leg (lane impl-923)

**STATUS: HELD at the owner build gate (2026-10-04 19:38 +07).** The owner
decided to cut ONE build carrying #989 + #991 + #992 + #998 and instructed
that no #923 work proceeds ahead of those. This lane was stopped mid-setup:
the preflight is complete, `just slop` and `just core` are green receipts, and
the app-target cycle (focused + full suite + the two mutation probes) had NOT
started — the guarded runner was killed while waiting for the host. Resume
steps are in `../../../../.report-923-HELD.md` (worktree root).

Lane `impl-923`, worktree `~/.herdr/worktrees/sendmeter/impl-923`, base
`3638202fe7eb230f20732c6c578080b39e64e0f5` (`origin/staging`).

This directory carries the **verification + discrimination** evidence for the
one leg #923 was left open for: *an account switch during an in-flight refresh,
driven against the production refresh coordinator with controllable responses.*
The prior lane's evidence (`../app-target-full.log.gz`, `../probe-C.*`) is
byte-unchanged; these files are additive.

## What the leg needed, and what was already in the tree at dispatch

The issue comment (2026-09-19, PR #975) recorded the leg as open because "the
test harness cannot mint a second live session on one model (the auth endpoints
are not stubbed)". That capability exists at this base — it landed with
**PR #979 (#933, `aef3444`)**:

- `Tests/SendmeterNativeTests/AccountSwitchInFlightAppTests.swift` — a hermetic
  PostgREST + auth transport (`AccountSwitchPostgREST`) that mints real SDK
  sessions through the stubbed `POST /auth/v1/token` endpoint, so
  `AppModel.signIn` / `authStateChanges` / `handleAuthEvent` drive the real
  account boundary on ONE model.
- Its tests hold a real repository request inside the URLSession transport,
  switch accounts while it is suspended, then release it and assert what
  happens. `testLateSuccessAfterAnAccountSwitchNeverPublishesTheOldAccountsData`
  drives the production entry point `AppModel.refreshAll()`.
- **PR #934 (`c273627`)** added the coordinator-level account-switch fence
  tests (`WorkspaceSyncCoordinatorTests.testAnAccountSwitchBetweenFetchAndReconcileWritesNothing`,
  `testAReconcileThatLosesItsAccountBeforeThePublicationReadPublishesNothing`).

This lane's route is therefore **route 1's substance, already in tree**: the
deliverable is the executed demonstration the issue asked for, the RED/GREEN
discrimination against the guard, the genuinely-unrelated-failure proof, and
the interaction statement. **No production code was changed and no duplicate
test was added** (the brief: "anything already delivered is out of scope — do
not rewrite it").

## Runs produced before the hold (raw exits in each log / trailer)

| file | command | outcome |
|---|---|---|
| `just-list.txt` | `just --list` | paste |
| `just-slop.log.gz` | `just slop` | exit **0** (trailer `SLOP_EXIT=0`) |
| `just-core.log.gz` | `just core` | exit **0** (trailer `CORE_EXIT=0`); `Executed 1510 tests, with 0 failures`; includes `WorkspaceSyncCoordinatorTests` (19/0 incl. both account-switch fence tests), `RefreshSlicePlanTests`, `AccountScopedFetchTests` |
| `just-gen.log.gz` | `just gen` | exit **0** |
| `guarded-xcodebuild-runner.sh` | the host-rule serialization runner (waits out peer `xcodebuild`s, `flock /tmp/sendmeter-xcodebuild.lock`, releases on every exit path) | tooling |
| `guarded-runner-R0.log.gz` | the runner's log for the first app-target run: started 12:37:40Z, saw peer pid 8913, was **killed at the hold before starting any xcodebuild** | no build started |
| `host-processes.txt` | closeout `pgrep`/sim/df receipts | no orphans of this lane |

## NOT RUN — held for the resumed lane (this is the remaining deliverable)

| planned file | planned command | why |
|---|---|---|
| `app-target-focused.log.gz` | CI-shape `xcodebuild test` for `AccountSwitchInFlightAppTests` + `SyncSurfacesAppTests` (exact command in `.report-923-HELD.md`) | the demonstration + the unrelated-failure proof |
| `app-target-full.log.gz` | CI-shape `xcodebuild test -only-testing:SendmeterNativeTests` | the full app-target gate |
| `probe-account-guard.diff` + `-red/-green/-restored` | `AccountScopedFetch.canApply` -> `true` mutation, focused RED, restore, GREEN | the discrimination receipt for the account/epoch guard |
| `probe-unrelated-publish.diff` + `-red/-green/-restored` | `RefreshSliceOutcomes.publishes(_:)` -> `didFullyRefresh` mutation, focused RED, restore, GREEN | re-establishes the merged probe-C at this head |
| `SHA256SUMS` | hashes of this directory | produced at closeout |

Both probe literals were pre-verified to occur exactly once (`count == 1`) at
this base; the mutation helper and runner are kept with this evidence
(`mutation-probe-helper.py`, `guarded-xcodebuild-runner.sh`) and in the lane
scratch dir (`~/.hermes/profiles/fleet-impl/cache/scratch/impl923/`).

Host rules relied on (verbatim from the brief): one `xcodebuild` at a time
host-wide (`/tmp/sendmeter-xcodebuild.lock`, stale-guard, release on every exit
path); `pgrep -fl xcodebuild` first; `-derivedDataPath <worktree>/.xcode-derived`;
`df -h /System/Volumes/Data` before heavy builds; `.xcode-derived` deleted when
done. The serialization runner and its log preambles are in
`guarded-xcodebuild-runner.sh` / the `*.log.gz` headers.
