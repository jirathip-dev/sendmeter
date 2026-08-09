-- #508-510: measured resisted movement may be cadence-led without a force
-- target. It still stores the raw trace and set_metrics; inTargetPct is null.
-- Static recording constraints and cadence-only manual rows are unchanged.
alter table public.tindeq_recordings
  drop constraint tindeq_recordings_reverse_set_shape_check;

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
        and set_metrics is not null
        and (
          (target_kg is null and target_low_kg is null and target_high_kg is null)
          or
          (target_kg is not null and target_low_kg is not null and target_high_kg is not null)
        ))
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

comment on constraint tindeq_recordings_reverse_set_shape_check on public.tindeq_recordings is
  'Resisted-movement sets require cadence provenance. Measured rows may omit a force target but always retain raw samples and set metrics.';
