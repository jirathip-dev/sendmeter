-- The watch's Date.localDateString formatted "yyyy-MM-dd" using
-- Calendar.current, which follows the device's Region setting — a Thai
-- Region defaults to the Buddhist calendar (Gregorian year + 543). Every
-- date-only value the watch wrote (sessions.date, health_metrics.date) could
-- come out 543 years ahead, e.g. 2026-07-12 stored as 2569-07-12. The client
-- fix forces Gregorian going forward; this backfills existing rows.
--
-- Idempotent: already-correct rows have year < 2400 and are untouched, so
-- this is safe to re-run if more BE-tagged rows land before every watch is
-- rebuilt with the fix.

update public.sessions
set date = (date - interval '543 years')::date
where extract(year from date) >= 2400;

-- health_metrics is keyed by (user_id, date); guard against a corrected
-- date already existing for that user instead of failing the whole batch.
do $$
declare
  r record;
begin
  for r in
    select user_id, date as old_date, (date - interval '543 years')::date as new_date
    from public.health_metrics
    where extract(year from date) >= 2400
  loop
    if exists (
      select 1 from public.health_metrics
      where user_id = r.user_id and date = r.new_date
    ) then
      raise notice 'health_metrics: skipped % -> % for user % (target date already has a row)',
        r.old_date, r.new_date, r.user_id;
    else
      update public.health_metrics
      set date = r.new_date
      where user_id = r.user_id and date = r.old_date;
    end if;
  end loop;
end $$;
