# #992 site-by-site enumeration (launch path + sync/replay path) — FIX ROUND 1

Complete re-audit at the fix-round head. Every `catch` (incl. typed catches) and
every `try?` in the audited file set was enumerated mechanically (line-numbered
listing over: `AppModel.swift`, `SendmeterNativeApp.swift`, `WeatherService.swift`,
`WatchConnectivityService.swift`, `TindeqBluetooth.swift`, `ManualWorkoutActivityManager.swift`,
`OfflineQueue.swift`, `QueueUploadCoordination.swift`, `CachePreparation.swift`,
`LocalCacheStore.swift`, `BackgroundSyncEngine.swift`, `HealthBackgroundSync.swift`,
`HealthMetricReconciliation.swift`, `AuthRecovery.swift`, `MutationRecoveryCoordinator.swift`,
`ForceLaunchRecovery.swift`, `DirectWriteReplay.swift`, `GuidedActivityMirror.swift`,
`SupabaseService.swift`, `Repositories.swift`) and each hit is classified below as
**raised**, **unraised (with the site's own reason)**, or **not same-shape**.

"Same shape" = a `catch`/`try?` with **no rethrow** and **no persisted line** at the
fix-round base (`e67adcd`). "Persisted" = a `.notice`-or-higher line in
`com.jirathip.sendlog.native` that `log show` (no `--info --debug`) carries.

Line numbers are the fix-round working tree; the F1 additions are marked **(F1)**.

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

19 op labels total; 1–5 pre-existing, 6–19 (+`surfaced` on 1–5) from this lane.

## B. Unraised — same shape, left silent, with the site's own reason

| Site | Count | Reason (about the site) |
|------|-------|-------------------------|
| Account-epoch guards (`if accountFetch.canApply … else` drops) | ~20 branches | The error belongs to a **superseded account**; attributing it to the account now in the model would be the bug (`AppModel.swift:7587` states it: "an old deletion result/error must not surface in its UI"). The account change itself is recorded by the auth path. |
| Cache-write diagnostics (`recordCacheFailure(...)` family: local/server upsert, deletes, confirmations, quarantine, cursor reset, watch lookup/adoption) | 12 sites | Their surface is the **Settings diagnostics ring** (a JSON sidecar the Settings screen renders), not the unified log — the ring is lossy by design, and these are cache-maintenance failures with a durable retry path (queue/repair), not launch/sync operations. |
| Local cache read guards (`try? workspace.localRevision / pendingEntityIDs / store.loadOne`) | ~28 | **Read-modify-write conflict guards, not operation boundaries**: `nil` means "cannot confirm", and the code deliberately takes no action (defers/recomputes). Store-level failures are represented at open time (`cache-prepare` → `CacheOpenFailure`) and corrupt rows are enumerated into the repair funnel (`local-data-repair`). A line per guard would fan out many per pass with no single operation identity. **Disclosed residual**: a DB-level read error inside an already-open store is not separately named. |
| `fetchRecordingSamples` `try?` (recording curve overlay) | 2 | A per-candidate **view fan-out**: a line per failed candidate reports curve traffic, not an operation; the recordings' own sync state is covered by `refresh-slice`/`queue-upload` lines and the curve degrades visibly (fewer sets drawn). |
| `WeatherService` local cache encode/decode `try?` | 4 | Best-effort **UserDefaults cache of a value held in memory and refetched every foreground**: decode failure = "no cached reading" (a state the card already renders, and the live fetch failure that follows offline is `weather-refresh`); encode is a plain Codable guard whose failure is not practically reachable. |
| `ManualWorkoutActivityManager.start` `Activity.request` catch | 1 | **Self-healing**: `sync(engine:)` retries `start` on every structural transition while `activity == nil`, so a failed request is transient; the absent lock-screen card is immediately visible, and a line would repeat per transition for as long as the request keeps failing. |
| `SupabaseService` `try?` set | 5 | (a) sidecar **directory** creation — the auth failure itself is rethrown by `guardedAuthCall` (site 5 carries it); (b) local removal during poisoned-session clearing — re-checked by `AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval` **after** the attempt; (c) 3× **error-body decode fallbacks** — the error is still thrown (`PostgRESTError` with a fallback message) and flows to sites 3/6. |
| `AuthRecovery.claims(from:)` `try?` | 1 | **Defensive decode** of a JWT we do not control: failure = no claims, and the token's actual usability is decided by the server, whose rejection surfaces at the refresh boundary (`SupabaseService` 158/282). |
| Watch session relay (`ensureFreshSession` catch) | 1 | Session-freshness is the **auth boundary** (`AuthRecoveryError` handled); non-auth errors relay a nil session and the watch's own next request re-drives; the delivery attempt itself is site 8. |
| Realtime subscribe (`RealtimeService`) | 1 | A subscribe failure is **connection state** (the reconnect loop owns it), not an error boundary; the failures it implies surface at sites 3/4/7. |
| Health silent path (`silentHealthRefresh`, morning-progress read/write, watch-readiness refresh) | ~5 | The **health-state row** is the surface: failures set `lastHealthSyncObservation = .failed` (`recordHealthSyncFailure`) which the row renders; the manual path already banners (site 5); `performWatchReadinessRefresh` **returns `.failed()` to the watch requester** (a returned outcome, like `fetchSlice`'s `.failure` — not a swallow). |
| `resolvePurgeGeneration` | 1 | **In-code documented** deliberate: "A background pass stays quiet about a rollout error — the public foreground refresh reports it." The same read's foreground failure is `refresh-slice`-named. |
| `TindeqBluetooth` (`try?` write / battery refresh, discarded `error:` params in `didFailToConnect` / `didDisconnect` / discovery) | 5 | **Flagged, not changed**: BLE is outside this lane's stated change set (fence). The exact sites are listed for a follow-up; widening the fence was refused as instructed. |

## C. Considered, not same-shape (no silent failure)

* **Rethrows**: `SupabaseService.guardedAuthCall` (records `.failure` in the ring,
  rethrows), `Repositories.swift:1624`, `computeAndPublishReadiness`'s
  `throw error` (lands in the health row / banner), `fetchSlice` → `.failure`
  (consumed by the slice funnel), `CachePreparation` → `.failure` (funnel).
* **Cancellation-only**: `catch is CancellationError` / `URLError.cancelled`
  guards (e.g. realtime reconcile, live-workout refetch, readiness pass) and the
  `try? await Task.sleep` timing waits.
* **Designed race outcomes**: `DurableQueueError.itemNotFound` (delete already
  done — the terminal state the call wanted), the `SendmeterNative`/12
  already-completed signal, unique-violation dedupe handlers
  (`Repositories.swift:1194/1520` fetch the existing row).
* **Background-sync outcome**: the engine used to lose the error with `.failed`;
  it now reports through `recordFailure` (site 12) before returning.
* **UI-only**: `SendmeterNativeApp` toast auto-dismiss hop; `Activity.end`
  (non-throwing).

## Changed sites' test coverage

* App suite (`SendmeterNativeTests/PersistedFailureLogAppTests`): sites 5
  (banner), 3 (`refresh-slice`), 6 (`queue-upload`) + the **F2 production-sink
  witness** (a freshly built `AppModel` must still hold
  `PersistedFailureSink.production`).
* Host suites (`just core`): `PersistedFailureLogTests` (line shape + the
  production-marker test), `WeatherServiceTests` (sites 18/19),
  `BackgroundSyncEngineTests` (site 12, both legs).
* Sites 9–11, 13–17 compile into the app target and go through the same record
  helper the suites assert; they need a dropped socket / legacy fixture / older
  account to drive at runtime (reported as not-driven, not as verified).
