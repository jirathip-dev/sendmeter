# #992 enumeration — mechanical sweep, dispositions, reconciliation (FIX ROUND 2)

The round-2 review found `BackgroundSyncService.schedule`'s submit `catch` missing
from the FIX ROUND 1 enumeration. The root cause was the **method**: the file set
was hand-picked (the launch/sync files I had audited), so a boundary file that was
never picked could not be missed *by the audit* — it was invisible to it. This
artefact replaces the method: **sweep every file, classify every hit**.

Scope: `native/SendmeterNative/Sources/**/*.swift` — all 169 files (app target +
SwiftPM targets), no file-level selection. Two mechanical commands, raw output
committed, every hit dispositioned, counts reconciled exactly.

## 1. The commands (reproduce with exactly these)

```
cd native/SendmeterNative
grep -rnE '(^|[^A-Za-z0-9_])(catch\b|try\?|try!)' Sources --include="*.swift" | LC_ALL=C sort > ../../docs/evidence/issue-992/enumeration-sweep.txt
grep -rnE '_ *= *(error|taskError)\b'                 Sources --include="*.swift"
```

* The first sweep is committed verbatim: `enumeration-sweep.txt` — **190 hits**
  across 35 files (`AppModel.swift` carries 108; the other 82 are spread over 34
  files). The regex also matches the words inside comments/strings; those hits are
  dispositioned (`NOT-SAME-SHAPE: comment / string`), not ignored.
* The second sweep (the `_ = error` swallow shape the round-1 review's F1 target
  came from) returns **no lines** at this head (`grep` exit 1). The two sites it
  used to find were raised in FIX ROUND 1 (sites 7 and 9).

Two hits reference code added by this fix round, and one hit per raised boundary
line: the sweep line numbers below are the committed tree's numbers.

## 2. Dispositions (every hit, machine-checkable)

`enumeration-dispositions.tsv` — one row per sweep hit: `file`, `line`,
`disposition`, `note`. The disposition vocabulary is closed:

| Bucket | Meaning |
|--------|---------|
| `RAISED (launch funnel)` | the catch/caller funnels through `recordLaunchFailure`/`surface(_:)`/`handleAuthSessionFailure` → a persisted `.notice` line exists |
| `RAISED (sync/replay)` | the site emits through `recordSyncReplayFailure` or the production emit (audit-ring observed) |
| `UNRAISED: cache diagnostics ring` | routes to `recordCacheFailure` (Settings diagnostics ring is the surface) |
| `UNRAISED: cache read guard` | `try?` read-modify-write guards / invalid-payload enumeration into the repair funnel |
| `UNRAISED: epoch guard` | a superseded account's error is dropped (attributing it to the current account would be the bug) |
| `UNRAISED: view fan-out` | per-candidate `fetchRecordingSamples` best-effort |
| `UNRAISED: health state` | the health-state row renders the failure |
| `UNRAISED: best-effort persistence` | local encode/decode where failure = "nothing cached/marker" (safe direction, refetched) |
| `UNRAISED: live view surface` | the failure is rendered where the tap happened (`errorMessage`/`traceState`/`refuseAction`) |
| `UNRAISED: self-healing retry` | ActivityKit mirror start, re-driven by the guarded path; absent card visible |
| `UNRAISED: auth sidecar` | sidecar dir / poisoned-session local removal; the auth failure itself rethrows at the boundary |
| `UNRAISED: error-body decode fallback` | the `PostgRESTError` is still thrown with a fallback message |
| `UNRAISED: defensive decode` | a value we do not control (JWT claims, style parse, one-or-many body) |
| `NOT-SAME-SHAPE: cancellation / timing` | `catch is CancellationError` / `URLError.cancelled` / `Task.sleep` waits |
| `NOT-SAME-SHAPE: returned status / rethrow` | returned `.failure`/outcome consumed by a raising caller, or a rethrow |
| `NOT-SAME-SHAPE: designed / documented outcome` | in-code documented terminal states (itemNotFound, 23505 dedupe, duplicate delivery, corrupt marker) |
| `NOT-SAME-SHAPE: comment / string (regex noise)` | the regex matched prose, not a code site |
| `FENCE: flagged, not changed` | `TindeqBluetooth` (outside this lane's change set) |

### Counts (must reconcile with the sweep)

| Bucket | Hits |
|--------|-----:|
| UNRAISED: cache read guard | 35 |
| NOT-SAME-SHAPE: cancellation / timing | 25 |
| UNRAISED: cache diagnostics ring | 24 |
| RAISED (launch funnel) | 23 |
| RAISED (sync/replay) | 17 |
| NOT-SAME-SHAPE: returned status / rethrow | 13 |
| UNRAISED: best-effort persistence | 12 |
| NOT-SAME-SHAPE: designed / documented outcome | 8 |
| UNRAISED: live view surface | 6 |
| UNRAISED: epoch guard | 5 |
| NOT-SAME-SHAPE: comment / string (regex noise) | 5 |
| UNRAISED: view fan-out | 3 |
| UNRAISED: health state | 3 |
| UNRAISED: defensive decode | 3 |
| UNRAISED: self-healing retry | 2 |
| FENCE: flagged, not changed | 2 |
| UNRAISED: auth sidecar | 2 |
| UNRAISED: error-body decode fallback | 2 |
| **Total** | **190** |

`RAISED` hits (40) are boundary lines that emit now: 23 through the launch funnel
(A1 sites 1–5 + every `surface()` caller) and 17 through the sync/replay channel —
including the two holes this round closes: `BackgroundSyncService.swift:54`
(`background-schedule`) and `RealtimeService.swift:107` (`realtime-subscribe`).

## 3. Reconciliation check (run it)

The disposition keys and the sweep lines must be identical sets — this is the
check that catches a future miss mechanically:

```
cd /Users/jirathip/.herdr/worktrees/sendmeter/impl-992
diff <(tail -n +2 docs/evidence/issue-992/enumeration-dispositions.tsv | cut -f1,2 | tr '\t' ':' | LC_ALL=C sort) \
     <(cut -d: -f1,2 docs/evidence/issue-992/enumeration-sweep.txt | LC_ALL=C sort) && echo RECONCILED
```

At this head: `RECONCILED` (190 ↔ 190, set-equal). The per-bucket counts sum to
190 by construction.

## 4. How a future site is checked without another review round

1. Re-run the two commands in §1 at the new head; `diff` the output against the
   committed `enumeration-sweep.txt`. Any added/removed line is a change in the
   boundary set — nothing else can move it.
2. For each changed line: append/update a row in `enumeration-dispositions.tsv`.
   A hit is acceptable without a persisted line only if its disposition is
   `UNRAISED: …` with a reason **about the site** (not about the audit's scope),
   or `NOT-SAME-SHAPE: …` (rethrow / returned status / cancellation / in-code
   documented), or `FENCE` (outside the lane's change set).
3. Re-run §3 and the bucket count table; the totals must still reconcile
   190 → new total.
4. `RAISED` inventory: site-table.md §A2 is the op-label list; a new `RAISED` hit
   must name its op there.

## 5. Disclosures

* `UNRAISED: live view surface` (6 hits in `Features/*` views): failures of
  user-initiated, tap-time fetches rendered in the view itself (`errorMessage`,
  `traceState`, `refuseAction`). They are visibly surfaced at the moment they
  happen, but they carry no persisted line — if the bar is ever widened from
  "launch + sync/replay failures" to "any failure a device transcript should be
  able to name", these are the next tranche (plus `HealthKitService.lastError`).
* The site-table's disclosed residual stands: a DB-level read error inside an
  already-open store is not separately named (the guards' `nil` means "cannot
  confirm"; open-time failures are `cache-prepare`).
* `TindeqBluetooth` (2 hits) remains flagged-only: the fence forbids editing it.
