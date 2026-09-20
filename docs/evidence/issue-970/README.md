# issue-970 evidence (lane impl-970: the phase-transition replay wait, base `fba3676`, head `365615a`)

Read `.report-1.md` (repo root) for the analysis and the verdicts; this file maps
the artifacts. Every `.log` is committed gzipped; `hashes.txt` carries the
sha256 of every file here. Raw exits per run are in `run-ledger.txt` (one line
per run: tag, wall clock, host load, **raw exit**, the test's own result line).

## The run ledger and the focused-test legs

| File | What it is |
| --- | --- |
| `run-ledger.txt` | every recorded run, in order, with its raw exit |
| `pre-fix-quiet-1.log.gz` | pre-fix (`fba3676`), focused test, quiet host — exit 0, `passed (1.377 s)` |
| `pre-fix-contended-1.log.gz` | pre-fix under host contention — exit 0, `passed (3.687 s)` |
| `pre-fix-contended-2.log.gz` | pre-fix under contention (two-phase harness) — exit 0, `passed (3.423 s)`; the killed first form's header is the top block |
| `pre-fix-contended-3.log.gz` | INFRA attempt: heavy contention, the runner never attached (no `Test Case` line), killed — `exit=137` |
| `fix-quiet-1..5.log.gz` | first post-fix pass (identical code; the head adds a 3-line comment rewording) — all exit 0 |
| `fix-contended-1..5.log.gz` | first post-fix contended pass — all exit 0 |
| `amend-quiet-1..5.log.gz` | **head-verified** (`365615a`), focused test — all exit 0, `passed (1.43/1.374/1.392/1.345/1.359 s)` |
| `amend-contended-1..5.log.gz` | **head-verified** under contention — all exit 0; one leg's test took `29.834 s` and still passed |
| `amend-class.log.gz` | the whole `PhaseTransitionReplayAppTests` class at the head, fresh container — `Executed 9 tests, with 0 failures … in 2.970 s`, exit 0 |

## RED proof and the cause probes (all in the scratch copy `/tmp/impl970-probes`, never the lane tree)

| File | What it is |
| --- | --- |
| `probe-splice.diff` | product splice: `enqueueDirectWrite` reports the item installed without persisting it (the durable write never happens) |
| `red-splice-fixed.log.gz` | the HARDENED test against that broken product — **exit 65**, `failed (180.478 s)`, three expiries each printing observed state + elapsed time |
| `probe-inject2.diff`, `probe-inject4.diff` | product splice: in-call delay before the durable write (2 s / 4 s) |
| `cause-inject2-old.log.gz`, `cause-inject4-old.log.gz`, `cause-inject4-fixed.log.gz` | the in-call ladder — the OLD budget tolerates 4 s (exit 0), i.e. its "≈3 s" is not a wall-clock bound |
| `probe-asyncpub30.diff` | product splice: the queue-count **publish** is deferred 30 s (durable item on disk, published count lagging — the shape the hosted log shows) |
| `cause-asyncpub30-old.log.gz` | deferred publish + the OLD budget — **exit 65**, `queue never reached 1; last observed 0`, and the print-only probe reports the budget it burned (`4.219 s`, then `3.734 s`) |
| `cause-asyncpub30-fixed.log.gz` | deferred publish + the HARDENED wait — **exit 0**, `passed (91.495 s)` |
| `cause-inject8-old.log.gz`, `cause-inject8-fixed.log.gz` | refused by the host's single-xcodebuild rule (exit 90 — a sibling lane held the slot) |
| `probe-comment-delta.diff` | the head's only delta from the first-pass code (a 3-line doc comment) |

## Corroboration (outside this lane's fence, reported not fixed)

| File | What it is |
| --- | --- |
| `corroboration-syncsurfaces-pr975.txt` | the same bounded-wait shape expiring in `SyncSurfacesAppTests.swift` (PR #975 head `d885c983`, attempt 1 failed / attempt 2 passed), verified against the raw job log |

## Gates

| File | What it is |
| --- | --- |
| `gate-exits.txt` | every gate's raw exit, in order |
| `gate-head-sha.txt` | the commit the gates ran against |
| `gate-just-slop.log.gz` | `just slop` (the CI-wired anti-slop gate) — exit 0 |
| `gate-anti-slop-focused.log.gz` | the anti-slop linter on the changed file — exit 1, 5 pre-existing `no-force-unwrap` findings |
| `gate-anti-slop-base-file.log.gz` | the same linter on the BASE blob — the same 5 findings (so they are not this diff's) |
| `gate-just-gen.log.gz`, `gate-check-watch-project.log.gz` | `just gen`, `just check-watch-project` — exit 0 |
| `gate-git-diff-check.log.gz` | `git diff --check fba3676..HEAD` — exit 0 |
| `gate-check-static-head.log.gz` | `validate-native-static.sh` at the head — exit 1, `Generated project is missing the Force source: ManualForceFullscreen.swift` (pre-existing) |
| `gate-check-static-base.log.gz` | the same script in a detached base worktree — exit 1, identical message |
| `gate-base-worktree.log.gz` | the base worktree add/remove bookkeeping |
| `just-fast-hang-state.txt`, `just-fast-hang-sample.txt` | `just fast` attempt 1: the issue-956 idle hang (log frozen, runner at 0.0 % CPU, main thread in `+[XCTWaiter waitForExpectations:…]`) — killed, exit 137 |
| `gate-just-fast-retry.log.gz` | `just fast` attempt 2 (`NSUnbufferedIO=YES`) — exit 0: core **1367** / watch-core **600** / health-core **66** tests, 0 failures |
| `gate-gitleaks-committed-surface.log.gz` | gitleaks **8.30.1** (the CI pin) over the committed surface (`git ls-files -co --exclude-standard` tree) with the workflow's exact flags — exit 0, `no leaks found` (8.16 MB scanned) |
