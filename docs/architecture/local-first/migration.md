# Migration order: the issues to file

One PR each. "Proof" is what the PR must run. "Device" marks what only a device can show: the PR says so and
does not claim it. Groups A, W, S1, E1 and the Blocks issues can run side by side; group C is queued `--serial`
because every slice edits `AppModel.swift`, and staging is not promoted to `main` between C1 and C6.

## Blocks repo, first (see `blocks.md`)

| # | Issue | Unblocks |
|---|---|---|
| B1 | BlocksUI: the iOS build fails on an ambiguous `Gesture`; add an iOS simulator build gate; cut a tag | U1 |
| B2 | swift: generated public initialisers for every kind | U1 |
| B3 | BlocksUI: a kit that builds for watchOS | U9 |

## A. The store (no behaviour change)

| # | Issue | Scope | Proof |
|---|---|---|---|
| A1 | store: `LocalStore`, the schema, the migrations folder | `Core/Store`, one `.sql` per step, all 12 tables and the local-only tables, the change-log triggers, `.drover/arch.toml` | `just core`: a recorded PostgREST row per table round-trips |
| A2 | store: reads and plain writes | `Workspace.fetch`, observation, create/update/soft-delete/restore for every table; the row types move from `Repositories.swift` | `just core` |
| A3 | store: the 8 RPCs as transactions | purge session, purge recording, health upsert with precedence, link recordings, merge sessions, rename tag, phone workout, erase all | `just core`: the cases of `supabase/tests/*.sql` as host tests |
| A4 | import: mapping and state | `Core/LegacyImport`: rows by column name, `ON CONFLICT DO NOTHING`, per-family state, old queue items as local writes | `just core`: run twice equals run once; a local edit survives |
| A5 | import: the reader | `Data/LegacyImport`: saved session, password, Apple; paged GETs. Not yet shown in the UI | Simulator tests against a stubbed `URLProtocol` |

## W. The watch hands records to the phone

| # | Issue | Scope | Proof |
|---|---|---|---|
| W1 | watch-core: `WatchSnapshot`, `WatchRecord`, `WatchRecordAck`, the outbox rule | Pure types and the resend rule | `just watch-core` (and Linux CI) |
| W2 | watch reads the snapshot | The phone publishes the application context; the watch's 7 table reads go | `just build-watch`. Device: context delivery |
| W3 | watch sends records | Outbox over `transferFile`, ack; the phone hands each record to its existing write path for now; Supabase, the token relay and the upload engine leave the watch target | `just build-watch`, the watchOS test job. Device: delivery, phone out of reach, relaunch |

## C. Cut-over and removal (`--serial`; no promotion to `main` inside)

Each cut-over moves one family's reads and writes to the store, imports that family, and turns off its fetch,
realtime and queue paths.

| # | Issue | Scope | Proof |
|---|---|---|---|
| C1 | cut-over: settings and phases | | `just core`, `just build-ios`, the app-target tests |
| C2 | cut-over: presets, routines, tags | | same |
| C3 | cut-over: health metrics | HealthKit reconcile writes the store | same. Device: HealthKit |
| C4 | cut-over: sessions, workouts, attempts, recordings | Watch ingest writes the store; the live mirror is WatchConnectivity only; the four direct repository calls in `Features` go | same. Device: a watch workout end to end |
| C5 | boot without an account | No login gate; the import screen when an old session is found; "Import from my old account" and "Erase all data" in Settings | App-target tests, UI smoke |
| C6 | remove Supabase from the app | Delete the files in `boundaries.md`; the package; associated domains; the account threading; the 55 machinery test files | `just ci` |
| C7 | remove Supabase from the repo | `supabase/`, two workflows, the scripts, gitleaks entries; rewrite `CLAUDE.md`, the README, the App Store and review notes; release note | `just ci`, the docs stale-command check |

## S. Sync

| # | Issue | Scope | Proof |
|---|---|---|---|
| S1 | sync core | `Core/Sync`: `SyncState`, `reduce`, the three rules, the phase repair, row ↔ field mapping, a fake transport | `just core`: two stores converge under each rule and each state edge |
| S2 | sync on CloudKit | `Data/CloudKit`: the `CKSyncEngine` transport; entitlements; the Settings switch and status row | `just build-ios`. Device: two devices, one Apple ID. Owner: portal container, schema deploy |
| S3 | sync edges | The account-changed choice, quota full, the deleted cloud copy, "Delete iCloud copy" | `just core` for the states. Device: each edge with a throwaway Apple ID |

## E. Export and MCP

| # | Issue | Scope | Proof |
|---|---|---|---|
| E1 | export writer | `Core/Export`, `Data/Export`, the Settings switch, Files exposure, the iCloud Drive folder when sync is on | `just core`: the folder from a seeded store, byte for byte. Device: iCloud Drive |
| E2 | mcp reads the export | `createExportStore`; delete auth, the Supabase transport and the dependency; README | `cd mcp && npm test`, `npm run typecheck`, `npm run dry-run`; a test that no network module is imported |

## U. Screens on Blocks (after B1 and B2)

| # | Issue | Scope | Proof |
|---|---|---|---|
| U1 | Blocks in the app | iOS 26 floor, the pin, the `SendmeterScreens` target, `ScreenHost`, the `Look`, `just gen-kinds`, and the first screen: Phases | `just core` (the built value), `just build-ios`, a 390 screenshot |
| U2 | Settings and the tag manager | | same |
| U3 | History list | | same |
| U4 | Session detail | Heart-rate and effort charts as app kinds | same |
| U5 | Dashboard | Cards, the readiness trend and the load projection as app kinds | same |
| U6 | Dashboard sheets | Recovery inputs, send conditions, training load | same |
| U7 | Workout tab | The routine list and preview; the runner stays live SwiftUI | same |
| U8 | Force tab | Analysis cards as app kinds; recording and the gauge stay live SwiftUI | same. Device: Bluetooth |
| U9 | Watch on the kit (after B3) | Watch views on Blocks' kit | `just build-watch`. Device |
| U10 | Close out | Delete what `DesignSystem.swift` no longer serves; freeze `AppModel.swift` | `just ci` |

## Later, dated

| # | Issue | When |
|---|---|---|
| L1 | Delete the importer and the Sign in with Apple entitlement | When the import window closes (open question 3) |

## Order at a glance

```
B1 B2 B3 ─────────────────────────────────────────────┐
A1 → A2 → A3 ─┬→ C1 → C2 → C3 → C4 → C5 → C6 → C7 ─┬→ U1 → U2 … U8 → U10
A4 → A5 ──────┤                                      │        U9 (after B3)
W1 → W2 → W3 ─┘                                      ├→ S2 → S3
S1 (after A1) ───────────────────────────────────────┤
E1 (after A2) → E2 ──────────────────────────────────┘
```
