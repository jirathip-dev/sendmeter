-- Realtime: let the web/iOS clients subscribe to postgres_changes for the
-- tables a watch write can touch, so a workout/recording/health row saved
-- from the watch shows up live without a manual reload. RLS still applies —
-- a client only ever receives change events for rows it can already select.
alter publication supabase_realtime add table
  public.sessions,
  public.tindeq_recordings,
  public.climb_workouts,
  public.climb_attempts,
  public.health_metrics;

-- Sleep-stage breakdown (deep/REM), already queryable from HealthKit's
-- sleepAnalysis without any new permission — the watch just needs to stop
-- collapsing every stage into one "asleep" total.
alter table public.health_metrics add column sleep_deep_hours real;
alter table public.health_metrics add column sleep_rem_hours real;

-- Respiratory rate: a new HealthKit read (Watch records it automatically
-- overnight). Additive only for now — stored and displayed, not yet folded
-- into the readiness score.
alter table public.health_metrics add column resp_rate_bpm real;
