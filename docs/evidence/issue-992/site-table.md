# #992 site-by-site enumeration (launch path + sync/replay path)

`level` = the os_log level of the app's own line at that site **at the base**
(`d61e715`). `persisted?` = whether `log show` (without `--info`/`--debug`)
on a device transcript would have carried a line from this site at the base.
`changed?` = what this lane did.

## Launch path (funnel: `recordLaunchFailure`)

| # | Site | Emitting code | Level (base) | Persisted? (base) | Changed? |
|---|------|---------------|--------------|-------------------|----------|
| 1 | `cache-prepare` | `AppModel.applyPreparedCache` | `.notice` | yes | `surfaced: false` added (deliberate degradation, no banner) |
| 2 | `local-data-repair` | `AppModel.applyLocalDataRepair` | `.notice` | yes | `surfaced: true` added (Settings repair notice) |
| 3 | `refresh-slice:<slice>` | `AppModel.recordPartialRefresh` | `.notice` | yes | `surfaced` = the error-surface policy verdict (computed before the record) |
| 4 | `refresh` | `refreshAll` catch | `.notice` | yes | `surfaced` = the error-surface policy verdict (computed before the record) |
| 5 | `banner` | `AppModel.surface(_:)` (all banner funnels, incl. auth paths) | `.notice` | yes | `surfaced: true` (this funnel IS the surface) |
| — | `surfaceLoadFailure` | (sets banner + Dashboard class; emits no own line) | — | via its callers (3, 4) | unchanged |

## Sync / replay path

| # | Site | Emitting code | Level (base) | Persisted? (base) | Changed? |
|---|------|---------------|--------------|-------------------|----------|
| 6 | durable-queue upload (drain + manual retry) | `AppModel.upload` catch | none — only queue-internal attempt/backoff state + `MutationUploadFailure` (queue file) | **no** | **new** `sync/replay failure op=queue-upload:<payload-case>` `.notice`; `surfaced` = `mode == .manual` (a manual-retry outcome row is the surface; an automatic drain is deliberately silent) |
| 7 | realtime reconcile (swallowed best-effort) | `refreshReconcileSlices` catch | none (`_ = error`) | **no** | **new** `op=realtime-reconcile` `.notice`, `surfaced: false` |
| 8 | watch delivery (application-context transmit) | `WatchConnectivityService.transmitContext` | none (`try?`) | **no** | **new** `op=watch-transmit` `.notice`, `surfaced: false` — and this one IS observed live: a booted simulator with no paired watch fails the transmit (Apple's `WCErrorCodeDeviceNotPaired`, `WCErrorDomain 7005`) and the app's line persists (`docs/evidence/issue-992/sim-happy-path.log`, `sim-failure-launch-funnel.log`) |
| 9 | pull (all entity deltas) | `refreshAll` / per-slice refresh | `.notice` | yes | covered by 3/4 (same funnel) |
| 10 | watch session relay (`becameActive` → `relayValidSessionToWatch`) | `ensureFreshSession` catch | none for non-auth errors (relays nil, silent) | **no** | not changed: the failure is session-freshness (auth boundary); `AuthRecoveryError` is already handled, and the delivery attempt itself is site 8. Disclosed as an open boundary. |
| 11 | watch completion adoption (phone ← watch inbox) | `acceptWatchCompletion` / `cachedWatchCompletionSession` | none in the unified log — `recordCacheFailure` writes the Settings diagnostics ring (a JSON sidecar) | **no** (ring only) | not changed: failures are local cache write/read failures on an adoption path that retries per foreground pass; the ring is their existing surface. Disclosed. |
| 12 | realtime subscribe | `RealtimeService` | none | **no** | not changed: a subscribe failure is connection *state* (degraded socket), not an error surface; the foreground/converge paths above carry the failures it implies. |
| 13 | BLE (Tindeq connect / disconnect) | `TindeqBluetooth.didFailToConnect` / `didDisconnectPeripheral` / service + characteristic discovery | none — the raw `error` is DISCARDED; only the user-facing `Status` copy is set | **no** | not changed in this lane: BLE is not part of the launch/sync-replay raise this lane owns, and `TindeqBluetooth.swift` is outside this lane's stated change set (the brief says stop+report instead of widening). Flagged as a follow-up with the exact sites: the `error:` parameters at `TindeqBluetooth.swift` `didFailToConnect` / `didDisconnectPeripheral` / `didDiscoverServices` / `didDiscoverCharacteristicsFor`. |
| 14 | health sync | `syncHealth` (banner via `surface`), `silentHealthRefresh` (records a failed health state) | none from the silent path | **no** for silent; `.notice` once for `syncHealth` via the banner funnel | not changed for the silent path: a background-quality refresh whose surface is the health-state row (`recordHealthSyncFailure`); `syncHealth` failures already emit through site 5. Disclosed. |

"Persisted? (base)" for sites 6–8 was verified by reading the base source at
`d61e715` (the only `Logger` instances in the app at base were the widget/intent
stubs and `AppModel.launchFailureLog`) and by the owner's device capture in
#992: zero app lines in a 36,882-line persisted transcript.

Changed sites' tests: 1–5 and 6 are asserted by
`PersistedFailureLogAppTests` (7's record call compiles into the app target;
it is not driven by a test — a realtime reconcile needs a socket event);
8 is observed live in the simulator unified log (the unpaired transmit fails
with `WCErrorDomain 7005`); `PersistedFailureLogTests` (host) pins the line
shape for both channels.
