-- #422: Reverse Action is a protocol, not a measurement-setup mode.
--
-- Static and Reverse Action capacity fits deliberately keep separate storage.
-- The existing columns remain the Static fit so watch builds and historical
-- rows keep their meaning; the new columns are exclusively Reverse Action.
alter table public.tindeq_tags
  add column reverse_cf_kg double precision,
  add column reverse_w_prime_kgs double precision,
  add column reverse_curve_fitted_at timestamptz,
  add column reverse_curve_recording_count integer;

-- Ordinary prescribed Reverse Action work is not automatically maximal
-- evidence. Authors can explicitly mark a measured protocol as a capacity
-- effort. Null on historical recordings means "pre-rule" and remains eligible
-- inside the Reverse Action model for backwards compatibility.
alter table public.tindeq_presets
  add column capacity_evidence boolean not null default false;

alter table public.tindeq_recordings
  add column capacity_evidence boolean,
  add column completed_reps integer,
  add column completion_status text
    check (completion_status in ('complete', 'partial'));

-- A Reverse Action preset may prescribe equipment resistance with no numeric
-- force target. The measured execution path still enforces a resolvable target
-- in the app; the target-free shape is for cadence-only spring execution.
alter table public.tindeq_presets
  drop constraint tindeq_presets_reverse_target_check;

-- Replace the #367/#400 shape checks with modality-aware forms. A measured
-- Reverse Action set keeps the original raw-trace/target/metrics requirements.
-- A cadence-only set is an explicitly clock-guided manual row: no samples or
-- manufactured kg values, but complete timing/progress provenance.
alter table public.tindeq_recordings
  drop constraint manual_force_attempt_shape,
  drop constraint tindeq_recordings_reverse_set_shape_check;

alter table public.tindeq_recordings add constraint manual_force_attempt_shape check (
  (source = 'dynamometer' and peak_kg is not null and avg_kg is not null)
  or
  (
    source = 'manual'
    and peak_kg is null
    and avg_kg is null
    and sample_count = 0
    and samples = '[]'::jsonb
    and planned_duration_ms is not null and planned_duration_ms > 0
    and actual_duration_ms is not null and actual_duration_ms > 0
    and duration_ms = actual_duration_ms
    and set_no is not null and set_no > 0
    and (
      (protocol_mode = 'hold'
        and external_load_kg is not null and external_load_kg >= 0
        and outcome is not null
        and rep_no is not null and rep_no > 0)
      or
      (protocol_mode = 'reverse_action'
        and external_load_kg is null
        and cadence_out_s is not null
        and cadence_return_s is not null
        and cadence_markers is not null
        and completed_reps is not null and completed_reps >= 0
        and completion_status is not null)
    )
  )
);

alter table public.tindeq_recordings add constraint tindeq_recordings_reverse_set_shape_check check (
  protocol_mode <> 'reverse_action'
  or (
    protocol_run_id is not null
    and set_no is not null
    and cadence_out_s is not null
    and cadence_return_s is not null
    and cadence_markers is not null
    and (
      (source = 'dynamometer'
        and target_kg is not null
        and set_metrics is not null)
      or
      (source = 'manual'
        and capacity_evidence is false
        and target_kg is null
        and target_low_kg is null
        and target_high_kg is null
        and set_metrics is null)
    )
  )
);

comment on column public.tindeq_presets.capacity_evidence is
  'For Reverse Action, opt-in maximal/capacity intent. Ordinary prescribed sets default false to avoid curve feedback loops.';
comment on column public.tindeq_recordings.capacity_evidence is
  'Frozen capacity candidacy. Null preserves pre-#422 measured Reverse Action rows as historical evidence.';
comment on column public.tindeq_recordings.completed_reps is
  'Clock-guided Reverse Action rep progress; not an observed movement count.';
comment on column public.tindeq_recordings.completion_status is
  'Whether the planned clock for this saved set completed or stopped partial.';
