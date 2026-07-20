-- SL-89: RPE becomes decimal (half-point steps). The watch banks the model's
-- predicted RPE as-is (e.g. 6.5) instead of rounding it to an integer, and the
-- phone editors step by 0.5. `load` is generated from rpe, so it has to be
-- dropped and recreated around the type change (kept integer via round()).
alter table public.sessions drop column load;
alter table public.sessions alter column rpe type numeric(3,1);
alter table public.sessions
  add column load integer generated always as ((round(duration_min * rpe))::integer) stored;

alter table public.climb_workouts alter column rpe_confirmed type numeric(3,1);
