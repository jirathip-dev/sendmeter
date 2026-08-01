-- #297 Part B2: record Warm-up under its own non-training zone. Without this,
-- its 5s/7s/10s holds would be inferred back into Power, Power Endurance and
-- Strength, polluting training balance and capacity trends.
--
-- The original zone check was inline/unnamed, so preserve #325's
-- name-independent lookup and widen only the check attached exactly to the
-- zone column. Additive: no rows or other schema objects are changed.
do $$
declare
  con record;
begin
  for con in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.tindeq_recordings'::regclass
      and c.contype = 'c'
      and c.conkey = array[(
        select a.attnum from pg_attribute a
        where a.attrelid = c.conrelid and a.attname = 'zone'
      )]
  loop
    execute format('alter table public.tindeq_recordings drop constraint %I', con.conname);
  end loop;
end $$;

alter table public.tindeq_recordings
  add constraint tindeq_recordings_zone_check
  check (zone in (
    'power',
    'strength',
    'power-endurance',
    'endurance',
    'warmup',
    'prehab'
  ));

comment on column public.tindeq_recordings.zone is
  'Zone this hold was performed under, from the armed zone/preset at save time (load-aware). Includes maintenance zones "warmup" (#297) and "prehab" (#325), recorded outside training balance. Null = unknown: pre-#259 row, freehand hold, or watch recording — readers fall back to inferring it from duration_ms.';
