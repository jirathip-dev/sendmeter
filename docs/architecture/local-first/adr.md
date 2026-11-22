# ADR: local-first Sendmeter (#1045)

## Summary

Decision: all data lives in one SQLite file on the iPhone (GRDB, already in the app), with today's table and column names. iCloud sync is an opt-in switch on Apple's CKSyncEngine and the user's private database; the watch hands finished records to the phone; the MCP server reads a JSON export folder. Supabase is only read, once, for the import; the app's minimum iOS rises to 26.
Slices: 31 issues in 6 groups: store (5), watch handoff (3), cut-over and Supabase removal (7), sync (3), export and MCP (2), screens on Blocks (10), plus one dated clean-up 90 days after the first local-first TestFlight build. The screens wait for two Blocks fixes (B1, B2); the watch stays plain SwiftUI until a third (B3).
Open questions: none. The owner's four answers (iOS 26 minimum, the three Blocks issues, the 90-day import window, no delete button) are written in.

## Question

Sendmeter's source of truth is a Supabase project. The phone keeps a cache of it and a queue of writes to it; the
watch writes to it with a token the phone relays; the MCP server reads it. How is the app built so that the device
is the source of truth, sync is the user's own iCloud and optional, there is no server, and every screen is Blocks?

What exists today (staging `8ed4a064`), which the decisions below lean on:

- 11 data tables, 8 RPCs, 2 realtime channels (`Data/Repositories.swift`, `Data/RealtimeService.swift`).
- GRDB 7.11.1 is pinned and compiled into `SendmeterCore`. The cache stores JSON blobs keyed by account.
- About 25 `Core` files and 55 test files exist only because the truth is remote: queue, replay, cursors, purge
  generations, auth recovery, account fences. `accountUserID` appears 741 times in `Core`.
- The watch reads 7 tables and writes 6. No full record crosses WatchConnectivity today.
- `mcp/` already reads through one `DataStore` interface of 8 methods (`mcp/src/transport.ts:109`).

## Decisions

### 1. The local store: SQLite through GRDB, typed tables, Postgres names kept

| Option | For | Against |
|---|---|---|
| SwiftData | Apple's own, little code | Its iCloud mirroring decides conflicts itself and reports no quota or account state; models must be all-optional with no unique keys; no host test of sync |
| Core Data + `NSPersistentCloudKitContainer` | Mature mirroring | The same limits as SwiftData, plus a second model language |
| **SQLite (GRDB) + our own sync on `CKSyncEngine`** | Already a dependency; runs in `just core` on the host; SQL fits the app's number queries; we own the conflict rules and see every sync state | We write the record mapping and the rules (done once, generically: decision 2) |

Decision: one file, `Application Support/SendmeterNative/sendmeter.sqlite`, typed columns. Tables and columns keep
their Postgres names, minus `user_id` (`shapes.md`). The file is in the device backup, so a local-only user is
still covered by an iPhone backup. It is not in the app group: one process writes it.

Keeping the names is what makes the rest small: **one schema, four generic adapters**, each driven by the table
list in the database, none with per-table code:

- import: a PostgREST JSON row is inserted by column name;
- sync: a row is a CloudKit record whose fields are the columns;
- export: a row is a JSON object whose keys are the columns;
- MCP: its row types (`SessionRow`, `RecordingRow`, …) do not change.

There is no account in the store. One device, one profile: `accountUserID`, the account fences and the
sign-out policies are deleted, not ported.

### 2. Sync: `CKSyncEngine`, one private zone, off by default

Decision: one custom zone `Sendmeter` in the private database of container `iCloud.com.jirathip.sendlog`. One
record type per table, record name `<table>:<key>`. Every value field is written through `encryptedValues`; the
two heavy columns (force samples, workout trace) are `CKAsset`s. Nothing is queried on the server: the engine
sends and fetches zone changes only.

SQLite triggers log every local change, so no writer can forget to mark a row. The engine's state, the on/off
switch and the last Apple ID seen live in the store. `sync.md` has the statechart and the rules; in short:

- last edit wins per record, by the row's `updated_at`; a tie keeps iCloud's copy;
- samples and traces are written once and never conflict;
- a day's health row with source data is never replaced by one without;
- a permanent delete beats an edit; a soft delete is an edit;
- a conflict is settled by rule and never shown to the user.

Sync never blocks a local read or write, in any state.

### 3. Phone and watch: the watch hands records to the phone

| Option | For | Against |
|---|---|---|
| Watch writes to CloudKit itself | Works with the phone away | Needs sync on, so a local-only user's watch data would be stuck; two writers |
| **Watch → phone over WatchConnectivity** | Works with sync off; one writer; no token, no network code on the watch | A record waits on the watch until the phone is in reach (as it does today when the token has expired) |

Decision:

- phone → watch: one `WatchSnapshot` in the application context (tags, presets, phase, 90 days of daily load,
  today's readiness, the RPE training rows). It replaces the token relay and the watch's 7 table reads.
- watch → phone: each finished record is a file sent with `transferFile`, kept in the watch's outbox until the
  phone acks it after its store transaction commits. Ingest is idempotent by id.
- live mirrors (`liveWorkout`, `liveForce`) stay `sendMessage`, as now. The `live_workouts` table and its realtime
  fallback are deleted.
- the watch's own readiness (#802) is sent as a health record; the phone applies the precedence rule on ingest.
- the watch never talks to CloudKit and links no Supabase.

### 4. Existing users: a one-time import that keeps ids

Decision: a small importer with no Supabase SDK (`URLSession` only) reads the user's rows over PostgREST and
inserts them with their ids and timestamps, `ON CONFLICT DO NOTHING`. So it can be rerun, it never overwrites
something the user did locally, and two devices that import the same account end with the same ids, which sync
then merges without duplicates.

- It signs in with the session the old build left in the Keychain (one refresh); with none, it asks once for
  email and password or Sign in with Apple.
- Writes still waiting in the old offline queue are applied to the store first: they are newer than the server.
- With no saved session the sign-ins offered are email and password, and Sign in with Apple. A passkey-only or
  magic-link-only user first sets a password by the reset mail.
- Progress is kept per table family, so a failed import resumes. The app is usable before and without it.
- Sync stays off afterwards.
- It only reads the hosted project. There is no "Delete my old cloud account" button (owner, q2990): the hosted
  data goes when the owner deletes the project.

The import window is 90 days from the first local-first TestFlight build (owner, q2989). The importer is the only
Supabase code left; the dated issue L1 deletes it (and the Sign in with Apple entitlement) when the window
closes, and the owner then deletes the hosted project. A user who has not imported by then keeps no old data.

### 5. The export for the MCP server: a folder of JSON, written by the app

| Option | For | Against |
|---|---|---|
| A copy of the SQLite file | One statement | Makes the store's schema the public contract; `mcp/` needs a SQLite reader |
| One JSON file | Simplest | Tens of MB rewritten on every export because of force samples |
| **`data.json` plus one write-once file per recording and trace** | Small file replaced whole; big files never rewritten; no new MCP dependency | A folder, not a file |

Decision: the format in `shapes.md`. It is off by default, a switch in Settings, written when the app goes to the
background if the store changed, and on "Export now". Location follows the sync switch, so data never reaches
iCloud unless the user turned sync on:

- sync on: the app's iCloud Drive folder, which a Mac sees at
  `~/Library/Mobile Documents/iCloud~com~jirathip~sendlog/Documents/Export`;
- sync off: `Documents/Export`, shown in Files under On My iPhone › Sendmeter, moved by AirDrop or Finder.

`mcp/` gains `createExportStore(dir)` behind the same `DataStore` interface and loses its Supabase client, auth
and network code. It is a one-way export, not a restore format.

### 6. Screens: pure builders in their own target, drawn by `BlocksView`

Decision: a screen is a pure function from a read model to a `Block`, in a new SwiftPM target `SendmeterScreens`
(imports `SendmeterCore` and `Blocks`, no SwiftUI), tested on the host by asserting on the built value. The app
target hosts it in one `ScreenHost` view with the app's own `Look` (built from `SendmeterPalette`, no tiles, no
swag) and handles its actions. Charts Blocks has no kind for (force curve, heat map, box plot, heart rate) are
app kinds drawn by the existing SwiftUI views. Recording, the live gauge and the routine runner stay live SwiftUI.

Blocks can draw a screen built on the device with no server: confirmed by a run. It cannot yet do so on an iPhone,
and not from typed values: `blocks.md` names three gaps as Blocks issues B1, B2 and B3 (owner, q2987). The
screens slices wait for B1 and B2; the watch stays plain SwiftUI until B3; nothing else in this ADR depends on
Blocks.

## Consequences

- No login screen, no account, no network needed. "Delete account" becomes "Erase all data".
- The app's privacy answer becomes "data not collected". `docs/app-store-checklist.md` and
  `docs/app-review-notes.md` are rewritten in the removal slice.
- About 25 `Core` files, `Data/Repositories.swift`, `Data/SupabaseService.swift`, `Data/RealtimeService.swift`,
  `Features/Auth`, the watch's upload engine and about 55 test files are deleted (`boundaries.md`).
- `supabase/`, `supabase-tests.yml`, `deploy-migrations.yml` and the migration scripts are deleted. The "merge to
  main applies DDL to production" trap goes with them.
- Debug builds no longer write production data: Xcode builds use CloudKit's development environment.
- The 8 RPCs become store transactions on the device. Their SQL regressions become host tests.
- Minimum iOS rises to 26 in slice U1 (owner, q2980): devices on iOS 17 to 25 stop getting updates and keep the
  last build shipped before U1. If that is still a Supabase build, it stops working when the hosted project is
  deleted; a TestFlight build cut after C7 and before U1 leaves them a working local-first app with the importer.
  The watch stays on watchOS 10 and does not link Blocks.
- A synced column is a CloudKit schema change: it must be deployed to CloudKit's production environment before the
  build that writes it ships. That is a manual step (below).
- Clock skew can make the wrong edit win a conflict. Accepted: one user, edits minutes apart at worst.
- Weather for send conditions still needs a network; it is the one feature that does.
- Staging passes through mixed states during the cut-over (group C in `migration.md`): no promotion to `main`
  between its first and last slice.

### Owner actions (nothing a lane can do)

- Apple Developer portal: create container `iCloud.com.jirathip.sendlog`; enable iCloud (CloudKit and iCloud
  Documents) and Push Notifications on both phone App IDs; the lane's profiles are then regenerated.
- CloudKit Console: deploy the schema from development to production before the first TestFlight build with sync,
  and after every slice that adds a synced column.
- Hosted Supabase: keep the production project readable for 90 days after the first local-first TestFlight
  build, then delete it. Until then it still holds every existing user's data; the app has no button to delete
  it sooner, so a user who wants that asks the owner.
- Device checks with a throwaway Apple ID: sync between two devices, quota full, sign-out, watch handoff,
  iCloud Drive export.

## Decided by the owner (2026-11-22)

| Ask | Decision | Where it lands |
|---|---|---|
| q2980 | Minimum iOS 26; devices on iOS 17 to 25 stop getting updates | Slice U1 raises the floor; consequences above |
| q2987 | File B1, B2 and B3 in Blocks; the screens wait for B1 and B2; the watch stays plain SwiftUI until B3 | `blocks.md`; group U and U9 in `migration.md` |
| q2989 | The hosted project stays readable for 90 days after the first local-first TestFlight build; then the owner deletes it and the importer is removed | Decision 4; L1 in `migration.md` |
| q2990 | No "Delete my old cloud account" button | Decision 4: the importer only reads |

There are no open questions.

## Hot files

| File or list | Class | Becomes |
|---|---|---|
| The store's schema steps (today the list inside `LocalCacheStore.migrate`) | central list | `Sources/Core/Store/Migrations/NNNN_<name>.sql`, one file per step, loaded from the bundle in name order. The old list is deleted with the cache |
| The app kinds table handed to `AppBlocks` | central list | `Sources/Features/Kinds/<Name>Kind.swift`, one per kind; the table is the generated `Kinds/Gen/AppKinds.swift`, written by `just gen-kinds` (which `just gen` runs) |
| Screens | would be a list | `Sources/Screens/<Name>Screen.swift`, one per screen; no list: an action handler names the next screen's type, the tab bar names its five roots |
| `Sources/App/AppModel.swift` (12,958 lines) | every cut-over slice edits it | No layout fixes that while it is being emptied: group C is queued `--serial`. It is frozen by the last screens slice; new state goes in `Sources/App/Models/<Feature>Model.swift` |
| `CLAUDE.md` | docs | Rewritten once, in the repo-removal slice; no split needed |

The exact `.drover/arch.toml` lines (the repo has no `arch.toml` yet; the first slice creates it):

```toml
# slice A1 (store)
[[collect]]
dir = "native/SendmeterNative/Sources/Core/Store/Migrations"
glob = "*.sql"

[[ban]]
pattern = "import GRDB"
paths = ["native/SendmeterNative/Sources/**"]
except = ["native/SendmeterNative/Sources/Core/Store/**"]
reason = "only the store touches SQLite: everything else calls LocalStore"

# slice C6 (Supabase removed from the app)
[[ban]]
pattern = "import Supabase"
paths = ["native/**", "ios/**"]
reason = "there is no server: the one-time import uses URLSession in Sources/Data/LegacyImport"

# slice S2 (CloudKit)
[[ban]]
pattern = "import CloudKit"
paths = ["native/**", "ios/**"]
except = ["native/SendmeterNative/Sources/Data/CloudKit/**"]
reason = "sync logic is pure in Core/Sync; only the transport sees CloudKit"

# slice U1 (Blocks)
generated = ["native/SendmeterNative/Sources/Features/Kinds/Gen/AppKinds.swift"]
generate = "just gen-kinds"

[[collect]]
dir = "native/SendmeterNative/Sources/Screens"
glob = "*Screen.swift"

[[collect]]
dir = "native/SendmeterNative/Sources/Features/Kinds"
glob = "*Kind.swift"

[[ban]]
pattern = "import SwiftUI"
paths = ["native/SendmeterNative/Sources/Screens/**"]
reason = "a screen is a pure value: SwiftUI lives in Features"

# the last screens slice
frozen = ["native/SendmeterNative/Sources/App/AppModel.swift"]
```
