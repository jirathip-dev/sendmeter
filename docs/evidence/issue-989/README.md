# Evidence — issue #989 (impl-989)

Intermittent reds of the SendmeterNative **app-target** suite
(`Tests/SendmeterNativeTests`), and the isolation/robustness fixes that make
the named offenders deterministic.

Head this evidence describes: `286d5bd` (branch `impl-989`, base `d61e715`; the two head commits after `4690079` are the evidence/report commits themselves).

## Layout

| path | what it proves |
|---|---|
| `pre-fix/pre-fix-run{1,2}-receipt.txt` + `.log.gz` | **Deterministic RED before the fix**: the same reused container reds `GuidedProtocolCompletionTests :114/:131/:156`, counts growing monotonically run to run (1/2/2 → 2/3/3). |
| `pre-fix/container-leak-state.txt`, `pre-fix/runs-log.tsv` | The leak itself: account `94000000-…-940`'s cache rows and each run's container snapshot. |
| `post-fix/quiet-q-exits.txt` + `quiet-run*.log.gz` | **Q-series** (two named classes): 10 attempts → 5 greens `Executed 4 tests, with 0 failures` (Q1/Q2/Q4/Q7/Q10) + 5 infra wedges (no assertion lines). |
| `post-fix/quiet-r-exits.txt` (+ `quiet-r-shared-exits.txt`) + `quiet3-run*.log.gz` | **R-series** (three classes incl. `GuidedLaunchRecoveryAppTests`): 5 greens `Executed 7 tests, with 0 failures` (R1/R3/R5/R6/R9) + infra wedges; the shared-device run (R3) recorded separately. |
| `post-fix/contended-exits.txt` + `contended-run*.log.gz` + `hog-status.txt` | **C-series** (deliberate host contention, per-run `HOGS_ACTIVE loadavg=` inside the log): greens under load + infra wedges; post-leg `hogs.sh status` receipts. |
| `post-fix/ci-shape-receipt.txt` + `ci-shape-suite.log.gz` | The **CI-shape** full app-target suite (`-only-testing:SendmeterNativeTests`, the `native-swift.yml` shape): `Executed 168 tests, with 0 failures`, `** TEST SUCCEEDED **`. |
| `ci/` | The CI failure receipts (run 37179622828 re-run @ `c3b72591`, `GuidedLaunchRecoveryAppTests :115/:116/:117`). |
| `mutation/` | **RED/GREEN proof**: `red-mutation.diff` (M1+M2+M3), `rg1-red-receipt.txt` (mutated: `Executed 7 tests, with 15 failures` — every hardened wait expired), `rg2-green-receipt.txt` (restored: `7 tests, 0 failures`), `restored-sha256.txt` (both files `5c43afc7…f2c48`), `rg-exits.txt` (full run ledger, incl. the two harness iterations below), `rg1-wrongproject-exhibit.log.gz` (the wrong-project exhibit). |
| `gates/` | `just --list`, `just gen` (×2, RAW 0), `just core` retry green (`1495 tests, 0 failures`), the two host-hang logs, `just check-watch-project` (exit 0). |
| `SHA256SUMS` | sha256 of every file in this directory. |

## Container statement (required by the brief)

- The runs were **not** container-erased between runs. The Q-series reused the
  `iphone17pro-sendmeter` data container; its leaked rows for account
  `94000000-…-940` grew across the series (16 → 22 → 24 → 25 → 31;
  `pre-fix/runs-log.tsv`). Between q8 and q9 an OS-level container replacement
  was observed (rows 683 → 0, new container path; cause not established — the
  device is shared with a sibling lane; this lane ran no `simctl erase` or
  `uninstall`). From q9 the leak re-accumulated, and the post-fix runs stayed
  green on both container generations.
- Later legs (R/C/CI-shape/mutation) ran on `impl-989-sim`, a `xcrun simctl
  clone` copy of the same device taken while no xcodebuild ran — a copy of the
  same reused container (`rows=226`, `acct940=6` at copy time) — because a
  sibling lane co-drove the shared device (their `xcodebuild` argv on
  `id=0E127B96…` overlapped this lane's runs). Nothing was erased.

## RED proof harness — two iterations, kept visible

1. The first mutation legs ran `xcodebuild` with a **relative `-project`
   path** while the shared runner `cd`s into the lane worktree: they built the
   LANE's sources, so the mutation never compiled (the exhibit log shows
   `SendmeterNative: /Users/…/impl-989/native/SendmeterNative` in the
   resolution). Fixed by pinning the ABSOLUTE scratch project path — the
   final receipts show the scratch path in both the command and the resolved
   packages. The mis-wired legs are preserved as exhibits, not deleted.
2. One RG1 attempt hit the runner's 1800 s lock-wait cap (`RAW=90`,
   `RG1_MUTATED RAW=90`), one more wedged at the simulator — both superseded by
   the final receipts.

## Host contention hygiene (per the orchestrator's host notice)

The legacy `hogs.sh` overwrote a single pidfile per `start`, so killing a
contended leg's wrapper could orphan a `yes` batch; the orchestrator reaped
the leaks. Fix, used by every contended leg after that notice: per-batch
pidfiles (`/tmp/impl989-hogs/batch.<pid>`) + `trap 'hogs.sh stop' EXIT INT TERM`
inside the run wrapper, the achieved load echoed **inside the run**
(`HOGS_ACTIVE loadavg=`), and a post-leg `hogs.sh status` line proving no
`yes` survived (`post-fix/hog-status.txt`).
