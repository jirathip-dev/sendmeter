# #992 site-by-site enumeration (launch path + sync/replay path) — FIX ROUND 1, re-based FIX ROUND 2

**FIX ROUND 2 method change**: the audited set is no longer a hand-picked file
list — it is the mechanical sweep of **every** file in
`native/SendmeterNative/Sources/**/*.swift` (169 files), with **every hit**
dispositioned and the counts reconciled. See
[`enumeration.md`](enumeration.md) for the commands, the raw output
(`enumeration-sweep.txt`, 190 hits), the per-hit dispositions
(`enumeration-dispositions.tsv`) and the reconciliation check. This file stays the
**op-label / family view**; the sweep artefact is the completeness proof.

Each hit is classified as **raised**, **unraised (with the site's own reason)**,
or **not same-shape**; counts below are the sweep's hit counts.

"Same shape" = a `catch`/`try?` with **no rethrow** and **no persisted line** at
the fix-round base (`e67adcd`). "Persisted" = a `.notice`-or-higher line in
`com.jirathip.sendlog.native` that `log show` (no `--info --debug`) carries.

Line numbers are the fix-round working tree; the F1 additions are marked **(F1)**,
the FIX ROUND 2 additions **(F2)**.

## A1. Already persisted at base; this lane added `surfaced`

The #964 round-2 funnel (`recordLaunchFailure`) already emitted `.notice` lines for
these; #992 added the `surfaced` field (computed **before** the emission).

| # | op label | Site | `surfaced` |
|---|----------|------|-----------|
| 1 | `cache-prepare` | `AppModel.applyPreparedCache` | `false` (deliberate degradation, no banner) |
| 2 | `local-data-repair` | `AppModel.applyLocalDataRepair` | `true` (Settings repair notice) |
| 3 | `refresh-slice:<slice>` | `AppModel` slice refresh | the error-surface policy verdict |
| 4 | `refresh` | `refreshAll` catch | the error-surface policy verdict |
| 5 | `banner` | `AppModel.surface(_:)` (all banner funnels, incl. auth) | `true` (this funnel IS the surface) |

## A2. Raised by this lane (new persisted lines)

| # | op label | Site | `surfaced` | Asserted by |
|---|----------|------|-----------|-------------|
| 6 | `queue-upload:<payload-case>` | `AppModel.upload` catch | `mode == .manual` | app suite (`PersistedFailureLogAppTests`) |
| 7 | `realtime-reconcile` | `AppModel.refreshReconcileSlices` catch (was `_ = error`) | `false` | app suite |
| 8 | `watch-transmit` | `WatchConnectivityService.transmitContext` (was `try?`) | `false` | observed live (simulator unified log, `WCErrorDomain 7005`) |
| 9 | **`live-workout-refetch` (F1)** | `AppModel.refreshLiveWorkoutRow` catch (was `_ = error`, the same shape as 7) | `false` | compile-in + the same funnel as 7 (needs a dropped realtime socket to drive) |
| 10 | **`hands-free-arm` (F1)** | `AppModel.armHandsFreeStream` catch (banner-visible, no line) | `true` | compile-in |
| 11 | **`queue-open` (F1)** | `AppModel` init: `DurableQueue` open (was `try?`) | `false` | compile-in; the error is kept and recorded after all stored properties exist |
| 12 | **`background-sync:<entity>` (F1)** | `BackgroundSyncEngine.run` prepare/apply catches (was `return … : .failed`, error lost) | `false` | `BackgroundSyncEngineTests` (both legs: failed prepare, failed apply) |
| 13 | **`legacy-direct-writes` (F1)** | `AppModel.adoptLegacyDirectWrites` fetch catch (deferral) | `false` | compile-in |
| 14 | **`legacy-phase-residues` (F1)** | `AppModel.recoverLegacyPhaseResidues` fetch catch | `false` | compile-in |
| 15 | **`legacy-tag-residues` (F1)** | `AppModel.recoverLegacyTagResidues` fetch catch | `false` | compile-in |
| 16 | **`legacy-health-residues` (F1)** | `AppModel.recoverLegacyHealthResidues` fetch catch | `false` | compile-in |
| 17 | **`session-delete-undo` (F1)** | `AppModel` delete-undo catch, queue-file write leg only (the `SendmeterNative`/12 already-completed race is carved out — designed outcome, not a failure) | `false` | compile-in |
| 18 | **`weather-refresh` (F1)** | `WeatherService.refresh(trigger:)` outer catch (sets `failed`, returns `false`, was silent) | `failed` (card shows Unavailable ⇔ `conditions == nil`) | `WeatherServiceTests` (3 tests: surfaced, suppressed, archive) |
| 19 | **`weather-climate` (F1)** | `WeatherService.fetchClimate` inner catch (suppressed archive failure) | `false` | `WeatherServiceTests` |
| 20 | **`background-schedule` (F2)** | `BackgroundSyncService.schedule` BGTaskScheduler submit catch (was `lastSubmittedAt = nil` and nothing else — the round-2 review's blocking finding) | `false` | compile-in; emission observable in the audit ring (BGTaskScheduler cannot be driven deterministically in the simulator) |
| 21 | **`realtime-subscribe` (F2)** | `RealtimeService` join catch (was `abandon` + return, error dropped — same shape as 7/9) | `false` | compile-in; emission observable in the audit ring |

21 op labels total; 1–5 pre-existing, 6–19 from FIX ROUND 1, 20–21 from FIX ROUND 2.

## B. Unraised — same shape, left silent, with the site's own reason

Counts are the sweep's hit counts for the family (per-hit detail:
`enumeration-dispositions.tsv`).

| Site | Hits | Reason (about the site) |
|------|-----:|-------------------------|
| Cache-write diagnostics (`recordCacheFailure(...)` family + the coordinators' `onFailure` callbacks + `AuthDiagnostics` ring I/O) | 24 | Their surface is the **Settings diagnostics ring** (a JSON sidecar the Settings screen renders), not the unified log — the ring is lossy by design, and these are cache-maintenance failures with a durable retry path (queue/repair), not launch/sync operations. Includes `WorkspaceSyncCoordinator` (5) and `MutationRecoveryCoordinator` (3) `onFailure` callbacks, which route a failure string + error into the same ring. |
| Local cache read guards (`try? workspace.localRevision / pendingEntityIDs / store.loadOne`, invalid-payload enumeration) | 35 | **Read-modify-write conflict guards, not operation boundaries**: `nil` means "cannot confirm", and the code deliberately takes no action (defers/recomputes). Store-level failures are represented at open time (`cache-prepare` → `CacheOpenFailure`) and corrupt rows are enumerated into the repair funnel (`local-data-repair`). A line per guard would fan out many per pass with no single operation identity. **Disclosed residual**: a DB-level read error inside an already-open store is not separately named. |
| Account-epoch guards (`if accountFetch.canApply …` / `guard … else { return }`) | 5 | The error belongs to a **superseded account**; attributing it to the account now in the model would be the bug (`AppModel.swift:7595` states it: "an old deletion result/error must not surface in its UI"). The account change itself is recorded by the auth path. Current-account branches of the same catches funnel into `surface()` → `banner` (raised). |
| Local best-effort persistence (`RoutineGate`, `LostRecordingNotice`, manual activity events, watch completion inbox, `WeatherService` reading/climate cache, `ManualWorkoutActivityManager` events) | 12 | Local encode/decode of a value the app **holds in memory and refetches on the next foreground/transition**: decode failure = "nothing cached" (a state the surface already renders); encode is a plain Codable guard whose failure is not practically reachable. |
| `fetchRecordingSamples` `try?` (recording curve overlay — `AppModel` ×2, `SessionDetailView` ×1) | 3 | A per-candidate **view fan-out**: a line per failed candidate reports curve traffic, not an operation; the recordings' own sync state is covered by `refresh-slice`/`queue-upload` lines and the curve degrades visibly (fewer sets drawn). |
| Health state (`silentHealthRefresh`, `runMorningHealthRefreshPass`, `HealthKitService.lastError`) | 3 | The **health-state row** is the surface: failures set `lastHealthSyncObservation = .failed` (`recordHealthSyncFailure`) / `lastError`, which the row renders; the manual path banners (site 5 → `banner`); the morning-read `_ = error`-successors return a status. |
| `SupabaseService` sidecar + decode fallbacks | 2 + 2 | (a) sidecar **directory** creation — the auth failure itself is rethrown by `guardedAuthCall` (site 5 carries it); local removal during poisoned-session clearing — re-checked by `AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval` **after** the attempt; (b) 2× **error-body decode fallbacks** — the error is still thrown (`PostgRESTError` with a fallback message) and flows to sites 3/6. |
| Defensive decode (`AuthRecovery.claims(from:)`, `DateSupport` style parse, `SupabaseService` one-or-many body) | 3 | **Values we do not control**: failure = no claims / a plain-text fallback / the other accepted body shape; the token's actual usability is decided by the server, whose rejection surfaces at the refresh boundary. |
| ActivityKit mirrors (`ManualWorkoutActivityManager.start`, `GuidedProtocolActivityManager.start`) | 2 | **Self-healing**: the manual manager's `sync(engine:)` retries `start` on every structural transition while `activity == nil`; the guided start is re-driven by the same presentation path (guarded by `activity == nil`); the absent lock-screen card is immediately visible, and a line would repeat per transition for as long as the request keeps failing. |
| Live view surface (`Features/*` tap-time fetches: `SessionDetailView`, `HistoryView`, `WorkoutView`, `ManualWorkoutFullscreen`, `ForceView` ×2) | 6 | The failure is rendered **where and when the tap happened** (`traceState = .failed`, `model.errorMessage`, `refuseAction(message)`); these are user-initiated one-shot reads, not launch/sync operations. Disclosed in `enumeration.md` §5 as the next tranche if the bar widens. `ForceView` rows are outside the fix fence (classification only). |
| `resolvePurgeGeneration` (`WorkspaceSyncCoordinator:292`) | (1; counted under §C returned status) | **In-code documented** deliberate: "A background pass stays quiet about a rollout error — the public foreground refresh reports it." The same read's foreground failure is `refresh-slice`-named. Returned in the resolution, not swallowed. |
| `TindeqBluetooth` (`try? write(.stop)` / `try? refreshBattery()`) | 2 | **Flagged, not changed**: BLE is outside this lane's stated change set (fence). The exact sites are listed for a follow-up; widening the fence was refused as instructed. |

## C. Considered, not same-shape (no silent failure)

Counts are sweep hits (`enumeration-dispositions.tsv`).

* **Rethrows / returned statuses (13)**: `SupabaseService.guardedAuthCall`
  (records `.failure` in the ring, rethrows), `CachePreparation` → `.failure`
  (consumed by the `cache-prepare` funnel), `fetchSlice` → `.failure` (slice
  funnel), `Repositories.swift:1624`, `computeAndPublishReadiness`'s `throw error`,
  `LocalCacheStore:1656`, `SignOutQueuePolicy` tuple,
  `ManualWorkoutLifecycleCoordinator` refusal outcome, `persistMorningHealthProgress`
  `false`, `performWatchReadinessRefresh` `.failed()` to the requester,
  `WorkspaceSyncCoordinator:292` resolution, `upload`'s rethrow branch.
* **Cancellation-only / timing (25)**: `catch is CancellationError` /
  `URLError.cancelled` guards (health passes, realtime reconcile, live-workout
  refetch, readiness pass, view fetches) and the `try? await Task.sleep` waits
  (`AppModel`, `Haptics`, views, `AsyncDeadline`, `SendmeterNativeApp` splash).
* **Designed / documented outcomes (8)**: `DurableQueueError.itemNotFound`
  (delete already done), the `SendmeterNative`/12 already-completed signal
  (carved out of site 17), unique-violation dedupe handlers
  (`Repositories.swift:1194/1520` fetch the existing row), duplicate lock-screen
  delivery (`ManualWorkoutActivityContent:65`), corrupt morning-progress marker
  dropped (`AppModel.loadMorningHealthProgress`), notification-permission denial
  (`ManualWorkoutRestScheduler:145` — a user decision), toast auto-dismiss hop,
  `purgeRecording`'s kept tombstone (queued delete owns retrying).
* **Comment / string regex noise (5)**: `RoutineGate:127`, `RoutineAudio:123/140`,
  `WorkoutView:1122`, `WatchConnectivityService:247` — prose containing "catch"
  or "try?", not code.
* **Background-sync outcome**: the engine used to lose the error with `.failed`;
  it reports through `recordFailure` (site 12) before returning.

## Changed sites' test coverage

* App suite (`SendmeterNativeTests/PersistedFailureLogAppTests`): sites 5
  (banner), 3 (`refresh-slice`), 6 (`queue-upload`), the **F2 production-sink
  identity witness** (a freshly built `AppModel` must hold
  `PersistedFailureSink.production`) and the **F2 round-2 emission witness**: a
  real failure driven through the UNSUBSTITUTED production binding must land in
  `PersistedFailureLog.recentEmissions()` (the audit ring) — the mutation that
  silences `.production`'s emitter while keeping `isProduction = true` (M2) turns
  it RED.
* Host suites (`just core`): `PersistedFailureLogTests` (line shape, production
  identity, and the audit-ring emission witness driven via
  `PersistedFailureSink.production`), `WeatherServiceTests` (sites 18/19),
  `BackgroundSyncEngineTests` (site 12, both legs).
* Sites 9–11, 13–17, 20–21 compile into the app target and go through the same
  record helper (20–21 through the production emit) the suites assert; 20–21 need
  BGTaskScheduler/manual scheduling and a dropped realtime socket to drive at
  runtime (reported as not-driven, not as verified).
