-- #494 (N2): recorded_at moved from the server's now() to the client clock
-- at all 7 insert sites (#487, F2) — correct, so a recording queued offline
-- and drained hours/days later keeps the moment it was actually captured.
-- But that also means a skewed device clock now writes recorded_at directly,
-- with nothing at the DB level to catch it — the exact Buddhist-calendar
-- class of bug (year +543) that 20260713060000_date_sanity_constraint.sql
-- guards `sessions.date` / `health_metrics.date` against. Without this, a
-- skewed clock's recording lands in no ACWR window, permanently.
--
-- Same generous bounds and rationale as that migration (a ~543-year
-- calendar-offset bug is what this catches, not normal variance): 2020-01-01
-- as the floor, now() + 7 days as the ceiling. `now()` (not `current_date`)
-- since recorded_at is a timestamptz with real time-of-day precision, unlike
-- the date-only columns the existing constraint covers.
--
-- Existing rows: none violate this. Verified against both remote projects
-- before writing this migration (read-only query, 2026-08-07):
--   dev  (mjkndfhjnipomjjhgsxv):  11 rows, recorded_at in [2026-07-13, 2026-08-01], 0 would violate
--   prod (zznsqmcewtzlnfoiefkk): 439 rows, recorded_at in [2026-04-16, 2026-08-06], 0 would violate
-- so this ADD CONSTRAINT (which validates all existing rows, same as the
-- precedent migration) is expected to apply cleanly on both.

alter table public.tindeq_recordings
  add constraint tindeq_recordings_recorded_at_sane
  check (recorded_at >= timestamptz '2020-01-01' and recorded_at <= now() + interval '7 days');
