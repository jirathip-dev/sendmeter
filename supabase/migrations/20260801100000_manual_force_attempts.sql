-- #367: sensorless, timed external-load attempts share Force sessions with
-- measured recordings, but must never manufacture force samples/statistics.
alter table public.tindeq_recordings
  alter column peak_kg drop not null,
  alter column avg_kg drop not null,
  add column source text not null default 'dynamometer'
    check (source in ('dynamometer', 'manual')),
  add column external_load_kg numeric,
  add column outcome text check (outcome in ('too_easy', 'good', 'failed')),
  add column planned_duration_ms integer,
  add column actual_duration_ms integer,
  add column rep_no integer;

alter table public.tindeq_recordings add constraint manual_force_attempt_shape check (
  (source = 'dynamometer' and peak_kg is not null and avg_kg is not null)
  or
  (source = 'manual' and peak_kg is null and avg_kg is null
    and sample_count = 0 and samples = '[]'::jsonb
    and external_load_kg is not null and external_load_kg >= 0
    and outcome is not null
    and planned_duration_ms is not null and planned_duration_ms > 0
    and actual_duration_ms is not null and actual_duration_ms > 0
    and duration_ms = actual_duration_ms
    and set_no is not null and set_no > 0
    and rep_no is not null and rep_no > 0)
);

comment on column public.tindeq_recordings.external_load_kg is
  'Nominal external load for sensorless attempts; never a measured force value.';
