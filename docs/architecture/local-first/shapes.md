# Data shapes

## The rule

A store table has the name and the columns of its Postgres table at staging `8ed4a064`, as the row types in
`Data/Repositories.swift:12-1072` decode them today, with these changes only:

- no `user_id`;
- `uuid`, `date`, `timestamptz` are `TEXT` (lowercase uuid, `YYYY-MM-DD`, UTC `YYYY-MM-DDTHH:MM:SS.sssZ`);
  `jsonb` and arrays are `TEXT` holding JSON; `boolean` is `INTEGER`;
- the two heavy columns move to their own tables (rows 3 and 6 below);
- `tindeq_tags` is keyed by `name` (its `id` is dropped), so a name cannot exist twice on any device;
- `updated_at` is set by a trigger on every local write: it is the conflict clock.

The store slice pins the column lists with a test: one recorded PostgREST row per table must insert and read
back with no key dropped.

## Tables (each synced table is one CloudKit record type of the same name)

| # | Table | Key | Columns | Rule |
|---|---|---|---|---|
| 1 | `sessions` | `id` | `date, type, type_label, duration_min, rpe, rpe_confirmed, load` (generated: `round(duration_min * rpe)`), `note, phase, group_id, workout_source, created_at, updated_at, deleted_at` | last edit |
| 2 | `climb_workouts` | `id` | `started_at, ended_at, avg_hr, max_hr, active_kcal, elevation_gain_m, attempts_detected, attempts_confirmed, rpe_predicted, rpe_confirmed, mean_effort, attempts_per_10min, session_id, source, created_at, updated_at` | last edit |
| 3 | `climb_workout_traces` | `workout_id` | `raw`: JSON `[[t_s, alt_m, motion_rms, hr], …]` (asset) | written once |
| 4 | `climb_attempts` | `id` | `workout_id, started_at, duration_s, elevation_gain_m, avg_hr, peak_hr, motion_intensity, effort_score, source, created_at, updated_at` | last edit |
| 5 | `tindeq_recordings` | `id` | `recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note, tag, side, group_id, protocol_run_id, set_no, rep_no, zone, source, external_load_kg, outcome, planned_duration_ms, actual_duration_ms, protocol_mode, target_kg, target_low_kg, target_high_kg, cadence_out_s, cadence_return_s, cadence_markers, set_metrics, setup_note, capacity_evidence, completed_reps, completion_status, updated_at, deleted_at` | last edit |
| 6 | `tindeq_recording_samples` | `recording_id` | `samples`: JSON `[[t_ms, kg], …]`, at most 48,000 pairs (asset) | written once |
| 7 | `tindeq_tags` | `name` | `hidden, cf_kg, w_prime_kgs, curve_fitted_at, curve_recording_count, reverse_cf_kg, reverse_w_prime_kgs, reverse_curve_fitted_at, reverse_curve_recording_count, side_mode, created_at, updated_at` | last edit |
| 8 | `tindeq_presets` | `id` | `name, hold_s, holds_s, reps, sets, rest_reps_s, rest_sets_s, target_kg, target_pct, pct_basis, pct_step, target_curve, alternate_sides, protocol_mode, cadence_out_s, cadence_return_s, tolerance_mode, tolerance_value, prepare_s, setup_note, capacity_evidence`, and the zone columns the row type decodes, `created_at, updated_at, deleted_at` | last edit |
| 9 | `routine_presets` | `id` | `name, steps` (JSON array of `{id, label, detail, seconds, repetitions, rest_seconds}`), `created_at, updated_at, deleted_at` | last edit |
| 10 | `phase_periods` | `id` | `phase, started_on, ended_on, created_at, updated_at, deleted_at` | last edit, then the one-open-period repair (`sync.md`) |
| 11 | `health_metrics` | `date` | `hrv_sdnn_ms, resting_hr, sleep_hours, sleep_deep_hours, sleep_rem_hours, body_mass_kg, resp_rate_bpm, readiness, zone, computed_at, updated_at` | health precedence |
| 12 | `user_settings` | fixed `settings` | `current_phase, phase_start_date, updated_at` | last edit |

Not carried over: `live_workouts` (the live mirror is WatchConnectivity only), `sync_purge_generations`,
`auth_events`.

There are no enforced foreign keys between synced tables: iCloud may deliver a child before its parent. A read
joins on the parent, so an orphan is never shown; a permanent delete removes the children in the same transaction.

## Local-only tables

```sql
create table sync_table (            -- which tables sync, and how; filled by the migrations
  name text primary key,
  rule text not null check (rule in ('last_edit', 'written_once', 'health')),
  asset_column text                  -- the column sent as a CKAsset, if any
);
create table sync_record (           -- one row per synced row
  table_name text not null,
  key text not null,
  system_fields blob,                -- the CKRecord's change tag; null = never sent
  pending integer not null default 0 check (pending in (0, 1, 2)),   -- 0 none, 1 save, 2 delete
  primary key (table_name, key)
);
create table sync_meta (key text primary key, value blob);
  -- 'enabled', 'engine_state', 'apple_id' (the user record name last synced with), 'last_synced_at'
create table import_state (family text primary key, completed_at text not null, rows integer not null);
create table export_state (key text primary key, value text);   -- 'enabled', 'store_version', 'exported_at'
```

A trigger on each synced table sets `sync_record.pending` and bumps the store version, unless the write is a
remote apply. A row never sent that is deleted leaves no tombstone.

## CloudKit

- Container `iCloud.com.jirathip.sendlog`, private database, zone `Sendmeter`.
- Record type: the table name. Record name: `<table>:<key>`, for example `sessions:<uuid>`,
  `health_metrics:2026-11-22`, `tindeq_tags:<name>`, `user_settings:settings`.
- Fields: every non-key column under its column name, in `encryptedValues` (`String`, `Double`, `Int64`); an
  asset column is a `CKAsset`. No index, no query, no reference field.
- A field the app does not know is kept on the record and ignored (a newer build's column).

## Watch ↔ phone (in `SendLogWatchCore`)

```swift
public struct WatchSnapshot: Codable, Equatable, Sendable {      // phone → watch, application context
    public var schemaVersion: Int
    public var tags: [WatchTag]                // name, hidden, cf_kg, w_prime_kgs, side_mode
    public var presets: [WatchPreset]
    public var phase: String
    public var dailyLoads: [DailyLoad]         // 90 days: date, load
    public var readiness: ReadinessSnapshot?   // today's, as ReadinessWatchBridge has it
    public var rpeTraining: [RPETrainingRow]   // avg_hr, mean_effort, attempts_per_10min, rpe_confirmed; newest 200
}

public enum WatchRecord: Codable, Equatable, Sendable {          // watch → phone, one file each
    case workout(WorkoutSaveBundle)            // session + workout + attempts + trace, as today, minus userId
    case tindeqRecording(TindeqRecordingInsert)   // row + samples
    case tindeqSession(PendingTindeqSession)
    case healthMetric(HealthMetricDay)
    public var id: UUID { get }                // the record's own id: ingest is idempotent by it
}

public struct WatchRecordAck: Codable, Equatable, Sendable {     // phone → watch, transferUserInfo
    public var stored: [UUID]
}
```

File metadata: `["kind": "record", "id": <uuid>, "schemaVersion": 1]`. The existing payload structs are reused;
`userId` and `enqueuedUserId` are removed from them.

## Export (read by `mcp/`)

```
Export/
  data.json                      replaced whole on each export
  samples/<recording-id>.json    [[t_ms, kg], …]                  written once
  traces/<workout-id>.json       [[t_s, alt_m, motion_rms, hr], …] written once
```

```json
{
  "format": "sendmeter-export",
  "version": 1,
  "exported_at": "2026-11-22T08:21:54.114Z",
  "app_version": "1.1.0 (212)",
  "tables": {
    "sessions": [{ "id": "…", "date": "2026-11-21", "type": "boulder", "duration_min": 90, "rpe": 7.5, "load": 675 }],
    "health_metrics": [], "phase_periods": [], "user_settings": [],
    "climb_workouts": [], "climb_attempts": [],
    "tindeq_recordings": [], "tindeq_tags": [], "tindeq_presets": [], "routine_presets": []
  }
}
```

- A row is an object keyed by column name, with PostgREST's JSON values, so `mcp/`'s row types stay as they are.
- Rows with `deleted_at` set are left out. A sample or trace file with no row left is removed on the next export.
- A reader that finds no file for a recording answers `samples: null`, which `SampleRow` already allows.
- `version` rises only when a key is removed or changes meaning; a reader ignores keys it does not know.
