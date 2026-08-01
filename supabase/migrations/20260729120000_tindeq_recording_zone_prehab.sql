-- #325: widen tindeq_recordings.zone to admit 'prehab' alongside the four
-- training qualities (#259's original check). Prehab is a low-load,
-- long-hold, daily-repeatable finger-tendon maintenance protocol recorded
-- OUTSIDE training balance — it is deliberately not a fifth TrainingQuality
-- (see src/lib/force-curve.ts's RecordedZone), so this widens only the
-- storage constraint, additive, no backfill, no other column touched.
-- #259's check is an inline, unnamed column check, so its generated name is
-- not guaranteed to be `tindeq_recordings_zone_check` on every environment
-- (a suffixed name like `..._check1` is possible if it collided at creation
-- time). `drop constraint if exists <guessed name>` would silently no-op in
-- that case, the `add constraint` below would succeed under the now-free
-- name, and the ORIGINAL constraint would keep rejecting 'prehab' — invisible
-- here, surfacing only as a failed insert in production. Find and drop every
-- check constraint on this table by NAME-INDEPENDENT lookup: rather than
-- matching on `pg_get_constraintdef` text (which would also match any check
-- on an unrelated `timestamptz` column, since those render as
-- "... with time zone"), match on `conkey` — the constraint's column
-- attnum(s) resolved to exactly the `zone` column. This can't collide with
-- another column's check no matter what the constraint's definition text
-- says, so the widen can't half-apply.
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
  check (zone in ('power', 'strength', 'power-endurance', 'endurance', 'prehab'));

comment on column public.tindeq_recordings.zone is
  'Zone this hold was performed under, from the armed zone/preset at save time (load-aware). Includes "prehab" (#325), recorded outside training balance. Null = unknown: pre-#259 row, freehand hold, or watch recording — readers fall back to inferring it from duration_ms.';
