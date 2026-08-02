-- #400: cadence-driven Reverse Action presets and set recordings.
--
-- This is deliberately append-only. Existing hang presets and recordings keep
-- their exact meaning through the `hold` defaults; Reverse Action adds a
-- protocol discriminator plus the prescription/analysis snapshots needed to
-- understand a set even if its preset is later edited or deleted.
alter table public.tindeq_presets
  add column protocol_mode text not null default 'hold'
    check (protocol_mode in ('hold', 'reverse_action')),
  add column cadence_out_s real not null default 3
    check (cadence_out_s between 0.5 and 30),
  add column cadence_return_s real not null default 3
    check (cadence_return_s between 0.5 and 30),
  add column tolerance_mode text not null default 'percent'
    check (tolerance_mode in ('percent', 'kg')),
  add column tolerance_value real not null default 10
    check (tolerance_value between 0.1 and 100),
  add column prepare_s integer not null default 5
    check (prepare_s between 0 and 60),
  add column setup_note text not null default '',
  add constraint tindeq_presets_reverse_target_check check (
    protocol_mode <> 'reverse_action'
    or target_kg is not null
    or target_pct is not null
    or target_curve
  );

alter table public.tindeq_recordings
  add column protocol_mode text not null default 'hold'
    check (protocol_mode in ('hold', 'reverse_action')),
  add column target_kg real,
  add column target_low_kg real,
  add column target_high_kg real,
  add column cadence_out_s real,
  add column cadence_return_s real,
  add column cadence_markers jsonb,
  add column set_metrics jsonb,
  add column setup_note text not null default '',
  add constraint tindeq_recordings_target_band_check check (
    (target_kg is null and target_low_kg is null and target_high_kg is null)
    or
    (target_kg is not null and target_low_kg is not null and target_high_kg is not null
      and target_low_kg <= target_kg and target_kg <= target_high_kg)
  ),
  add constraint tindeq_recordings_cadence_check check (
    (cadence_out_s is null and cadence_return_s is null)
    or
    (cadence_out_s between 0.5 and 30 and cadence_return_s between 0.5 and 30)
  ),
  add constraint tindeq_recordings_cadence_markers_check check (
    cadence_markers is null or jsonb_typeof(cadence_markers) = 'array'
  ),
  add constraint tindeq_recordings_set_metrics_check check (
    set_metrics is null or jsonb_typeof(set_metrics) = 'object'
  ),
  add constraint tindeq_recordings_reverse_set_shape_check check (
    protocol_mode <> 'reverse_action'
    or (
      protocol_run_id is not null
      and set_no is not null
      and target_kg is not null
      and cadence_out_s is not null
      and cadence_return_s is not null
      and cadence_markers is not null
      and set_metrics is not null
    )
  );
