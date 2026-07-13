-- Guard against the Buddhist-calendar date bug (see
-- 20260712040000_fix_buddhist_dates.sql) recurring from a stale or
-- reinstalled watch client: a Thai-region device's Calendar.current pushes
-- date-only values 543 years ahead (e.g. 2026-07-13 becomes 2569-07-13).
-- The fix that migration applied is client-only, so nothing at the DB
-- level actually stops it from happening again.
--
-- Bounds are deliberately generous — this exists to catch a ~543-year
-- calendar-offset bug, not to police normal logging: sessions/health
-- metrics are always same-day or recent-past entries in this app, so a
-- multi-year-past or week-plus-future date is never legitimate.

alter table public.sessions
  add constraint sessions_date_sane
  check (date >= date '2020-01-01' and date <= current_date + interval '7 days');

alter table public.health_metrics
  add constraint health_metrics_date_sane
  check (date >= date '2020-01-01' and date <= current_date + interval '7 days');
