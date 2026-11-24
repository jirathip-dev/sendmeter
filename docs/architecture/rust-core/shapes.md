# Data shapes

Rust is the source of every shape here. Swift gets them from UniFFI.

## The door: events in, effects out (`sm-app`)

```rust
pub struct Config {
    pub store: StoreAt,                    // File(path), or Memory for tests and previews
    pub app_version: String,
}

pub struct Stamp { pub now_ms: i64, pub utc_offset_s: i32 }    // the host's clock, with every event

pub enum Event {
    Open { route: Route },                 // draw this screen
    Close { route: Route },
    Act { route: Route, action: String },  // a Blocks action as JSON, as BlocksView hands it over
    Foreground, Background, Tick,
    Ble(BleEvent),
    Cloud(CloudEvent),
    Health(HealthDay),
    Watch(WatchIn),                        // Record(bytes), Reachable(bool)
    Picked { purpose: Pick, name: String, bytes: Vec<u8> },    // a file the user chose
    Pixels { width: u32, height: u32, rgba: Vec<u8> },         // a screenshot, decoded by the host (#1056)
}

pub enum Effect {
    Screen { route: Route, json: String }, // a whole Blocks screen
    Ops { route: Route, json: String },    // Blocks row ops for a screen already shown
    Nav(Nav),                              // Push(route), Sheet(route), Back, Tab(id), Live(view)
    Ble(BleCommand),
    Cloud(CloudCommand),
    Live(LiveFrame),                       // what the SwiftUI live views draw
    Watch(WatchOut),                       // Snapshot(bytes), Ack(ids)
    Widget(Vec<u8>),                       // the readiness widget's payload
    Pick(Pick),                            // open the file or photo picker
    Save { name: String, bytes: Vec<u8> }, // a file of the export folder
    Wake { after_ms: u32 },                // send Tick then: a timer, or the next step of long work
}
```

`handle` returns `Vec<Effect>` and never fails: a refused action is a screen or a toast, a store error is a
screen that says so. `open` returns `Result<App, OpenError>` (the file cannot be opened, a migration failed).

A `Route` is the path a Blocks row opens: `today`, `log/sessions`, `session/<id>`, `board/route/<id>`,
`settings`. Each screen file names its own. The five tabs and their root routes come from the core as one
Blocks layout.

Days are computed in Rust from `Stamp` by plain arithmetic. No calendar object exists in the core, so the
Buddhist-calendar defect cannot recur. The host passes numbers, never formatted dates.

`LiveFrame` carries only what a live view shows now: the elapsed and rest times as instants to count from, the
current force and its target band, the rep and set counters, the last attempts, the route, the heart rate. It
is small on purpose: what does not fit one screen is not in it (`adr.md`, decision 5).

## Bluetooth (`sm-domain::ble`)

```rust
pub enum BleCommand {
    Scan { gear: Gear, filter: ScanFilter },
    StopScan { gear: Gear },
    Connect { device: DeviceRef },
    Disconnect { device: DeviceRef },
    Subscribe { device: DeviceRef, characteristic: Uuid },
    Write { device: DeviceRef, characteristic: Uuid, bytes: Vec<u8>, mode: WriteMode, token: u32 },
}

pub enum BleEvent {
    Radio(RadioState),                             // On, Off, Denied, Unsupported
    Found { device: DeviceRef, name: Option<String>, services: Vec<Uuid> },
    Connected { device: DeviceRef, writable: Vec<Characteristic> },
    ConnectFailed { device: DeviceRef },
    Dropped { device: DeviceRef },
    Wrote { token: u32 },
    WriteFailed { token: u32 },
    Value { device: DeviceRef, characteristic: Uuid, bytes: Vec<u8> },
}

pub enum Gear { Tindeq, Board(BoardKind) }
```

`ScanFilter` carries the services and name prefixes of #1047's `protocols.md` and the Tindeq service UUID
(`ForceEngine.swift`). #1047's link statechart is kept; its commands are these.

## The store's statements (`sm-store`)

```rust
pub struct Query { name: &'static str, sql: &'static str }     // fields private: made only by the build script

pub mod sql { pub const SESSIONS_IN_WEEK: Query = /* queries/sessions_in_week.sql */; /* … one per file */ }

impl Db {
    pub fn rows<T>(&self, q: Query, params: impl Params, read: fn(&Row) -> Result<T, StoreError>) -> Result<Vec<T>, StoreError>;
    pub fn run(&self, q: Query, params: impl Params) -> Result<usize, StoreError>;
}
```

There is no function that takes SQL as text.

## Synced records

One CloudKit record type per synced table, in zone `Sendmeter` of the private database of
`iCloud.com.jirathip.sendlog`, record name `<table>:<key>` (#1045, kept). A field is a non-key column under
its column name, written through `encryptedValues` (`String`, `Double`, `Int64`); an asset column is a
`CKAsset`. Ids, days and times are strings (lowercase uuid, `YYYY-MM-DD`, UTC `YYYY-MM-DDTHH:MM:SS.sssZ`);
booleans are 0 or 1; a list or object is a string holding JSON. A generated column is not a field. No index,
no query, no reference. A field the app does not know is kept on the record and ignored.

| # | Record type | Key | Fields | Rule |
|---|---|---|---|---|
| 1 | `sessions` | `id` | `date, type, type_label, duration_min, rpe, rpe_confirmed, note, phase, group_id, workout_source, created_at, updated_at, deleted_at` | last edit |
| 2 | `climb_workouts` | `id` | `started_at, ended_at, avg_hr, max_hr, active_kcal, elevation_gain_m, attempts_detected, attempts_confirmed, rpe_predicted, rpe_confirmed, mean_effort, attempts_per_10min, session_id, source, created_at, updated_at` | last edit |
| 3 | `climb_workout_traces` | `workout_id` | `raw`: JSON `[[t_s, alt_m, motion_rms, hr], …]` (asset) | written once |
| 4 | `climb_attempts` | `id` | `workout_id, started_at, duration_s, elevation_gain_m, avg_hr, peak_hr, motion_intensity, effort_score, source, route_id, route_name, route_grade, outcome, created_at, updated_at` | last edit |
| 5 | `tindeq_recordings` | `id` | `recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note, tag, side, group_id, protocol_run_id, set_no, rep_no, zone, source, external_load_kg, outcome, planned_duration_ms, actual_duration_ms, protocol_mode, target_kg, target_low_kg, target_high_kg, cadence_out_s, cadence_return_s, cadence_markers, set_metrics, setup_note, capacity_evidence, completed_reps, completion_status, updated_at, deleted_at` | last edit |
| 6 | `tindeq_recording_samples` | `recording_id` | `samples`: JSON `[[t_ms, kg], …]`, at most 48,000 pairs (asset) | written once |
| 7 | `tindeq_tags` | `name` | `hidden, cf_kg, w_prime_kgs, curve_fitted_at, curve_recording_count, reverse_cf_kg, reverse_w_prime_kgs, reverse_curve_fitted_at, reverse_curve_recording_count, side_mode, created_at, updated_at` | last edit |
| 8 | `tindeq_presets` | `id` | `name, hold_s, holds_s, reps, sets, rest_reps_s, rest_sets_s, target_kg, target_pct, pct_basis, pct_step, target_curve, alternate_sides, protocol_mode, cadence_out_s, cadence_return_s, tolerance_mode, tolerance_value, prepare_s, setup_note, capacity_evidence`, the zone columns today's row type decodes, `created_at, updated_at, deleted_at` | last edit |
| 9 | `routine_presets` | `id` | `name, steps, created_at, updated_at, deleted_at` | last edit |
| 10 | `phase_periods` | `id` | `phase, started_on, ended_on, created_at, updated_at, deleted_at` | last edit, then the one-open-period repair |
| 11 | `health_metrics` | `date` | `hrv_sdnn_ms, resting_hr, sleep_hours, sleep_deep_hours, sleep_rem_hours, body_mass_kg, resp_rate_bpm, readiness, zone, computed_at, updated_at` | health precedence |
| 12 | `user_settings` | fixed `settings` | `current_phase, phase_start_date, grade_scale, mass_unit, updated_at` | last edit |
| 13 | `board_setups` | `id` | `name, layout, angle, angle_adjustable, leds_above_holds, led_map, created_at, updated_at` | last edit |
| 14 | `routes` | `id` | `board, layout, name, setter, grade, angle, holds, note, origin, created_at, updated_at` | last edit |
| 15 | `sends` | `id` | `route_id, route_name, route_setter, route_holds, venue, board, setup_id, angle, climbed_at, day, outcome, tries, repeat, grade, feel, quality, mirrored, note, session_id, origin, updated_at` | last edit |

Rows 1 to 12 are #1045's tables, unchanged but for two additions:

- **Row 4** gains the route tag #1048 needs: `route_id` (a `routes` id, when on a board), `route_name`,
  `route_grade`, and `outcome` (`fell`, `sent`).
- **Row 12** gains the two choices of #1046's Settings screen, `grade_scale` (`v`, `font`) and `mass_unit`
  (`kg`, `lb`). The Apple Health switch and paired gear are per device and not synced.

**Rows 13 to 15** are #1047's `BoardSetup`, `Route` and `Send` as tables. `led_map`, `holds` and `route_holds`
hold JSON (`null` for a name-only route). `sends` is not board-only: #1046's logbook lists gym and crag ticks,
so `venue` is `board`, `gym` or `crag` and `board` may be empty. `repeat` and `feel` (`soft`, `solid`,
`sandbag`) come from #1046's send sheet; a flash is `outcome = sent, tries = 1`.

There are no enforced foreign keys between synced tables (#1045, kept): iCloud may deliver a child first.

A later synced table is one more row of this list, added by a migration file and never by changing a row
above. #1065's personal force model, if it stores a state per hand and grip, adds its table this way.

## What crosses the transport (`sm-sync`)

```rust
pub struct CloudRecord {
    pub kind: String,                      // the table
    pub name: String,                      // "<table>:<key>"
    pub fields: Vec<(String, Value)>,      // each written through encryptedValues
    pub asset: Option<Asset>,              // the heavy column of rows 3 and 6: Asset { field, bytes }
    pub system: Option<Vec<u8>>,           // CloudKit's archived system fields; opaque to the core
}

pub enum Value { Text(String), Int(i64), Real(f64), Null }

pub enum CloudEvent {
    Account(Account),                      // Available { user }, None, Restricted
    ZoneReady,
    Fetched { changed: Vec<CloudRecord>, deleted: Vec<String> },
    Sent { saved: Vec<Saved>, failed: Vec<Failed> },
    Failed(TransportFailure),              // Network, Quota
    ZoneGone(Gone),                        // Deleted, Purged, EncryptedDataReset
    EngineState(Vec<u8>),                  // CKSyncEngine's saved state, to keep in sync_meta
    BatchWanted { max_records: u32, max_bytes: u32 },
}

pub enum Failed {
    Conflict { name: String, server: CloudRecord },
    Unknown { name: String },              // deleted on the server
    Quota { name: String },
    Other { name: String, retry: bool },
}

pub enum CloudCommand {
    Start { engine_state: Option<Vec<u8>> },   // make the engine
    Stop,
    MarkPending { saves: Vec<String>, deletes: Vec<String> },
    Send(Batch),                           // the answer to BatchWanted
    Fetch,                                 // "Sync now"
    DeleteZone, Forget,
}
```

`system` stays on the device that got it; it never travels between devices. `SyncState`, `SyncEvent` and
`reduce` are in `sync.md`.

## Local-only tables

Four of #1045's five (`sync_table`, `sync_record`, `sync_meta`, `export_state`), unchanged; `import_state` is
gone with the import. With:

- `schema_step (name text primary key)`: the migrations applied;
- `device (key text primary key, value text)`: the known Tindeq and boards, the current wall, the Apple Health
  switch. Never synced.

Two SQL functions the store registers on its connection replace #1045's "unless the write is a remote apply"
flag and its trigger clock: `sm_now()` returns the event's `Stamp` as text, `sm_remote()` is 1 while sync
applies a record. The triggers that stamp `updated_at` and mark `sync_record.pending` call them.

## The board app kind's props

```rust
pub struct BoardProps {
    pub size: (u8, u8),                    // columns, rows of holes
    pub label: Option<String>,             // "KILTER 40°"
    pub lit: bool,
    pub holds: Vec<(u8, u8, HoldRole)>,
    pub tap: Option<String>,               // the action a hole sends, with { "cell": [c, r] }; none: read-only
}
```

`size`, not `rows`: BlocksUI's op `apply` rewrites an app block's own `rows` field today (`blocks.md`, G2).
`mascot` has `name` (`workout`, `force`) and `size`.

## Unchanged from #1045

`WatchSnapshot`, `WatchRecord` and `WatchRecordAck` (Swift, in `SendLogWatchCore`, JSON on the wire): the core
reads and writes the same JSON with serde, held equal by `fixtures/watch/`. The export folder
(`data.json`, `samples/`, `traces/`): written by the core as `Effect::Save` files.
