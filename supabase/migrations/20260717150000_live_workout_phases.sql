-- Live-workout phase timestamps: enough state for the phone to mirror the
-- watch's climbing/resting timer with second precision (heartbeats are ~5s
-- apart, but these are absolute timestamps so the phone renders exact
-- countdowns; the watch also beats immediately on phase transitions).
alter table public.live_workouts
  add column climbing_since timestamptz,
  add column rest_started_at timestamptz,
  add column rest_target_s integer check (rest_target_s between 0 and 3600);
