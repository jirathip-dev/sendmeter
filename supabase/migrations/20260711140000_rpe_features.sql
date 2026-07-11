-- Denormalized per-workout RPE features so the watch can fit its ridge
-- regression from a single-table select, with labels frozen to what the
-- predictor saw at workout time. Written by the watch at save time.

alter table public.climb_workouts
  add column mean_effort real,
  add column attempts_per_10min real;

-- Backfill from climb_attempts for existing workouts.
update public.climb_workouts w
set mean_effort = a.me,
    attempts_per_10min = a.cnt / nullif(extract(epoch from (w.ended_at - w.started_at)) / 600.0, 0)
from (
  select workout_id, avg(effort_score) as me, count(*)::real as cnt
  from public.climb_attempts
  group by workout_id
) a
where a.workout_id = w.id;

update public.climb_workouts
set mean_effort = 0, attempts_per_10min = 0
where mean_effort is null;
