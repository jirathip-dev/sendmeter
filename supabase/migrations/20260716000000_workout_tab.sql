-- Workout tab (SL-41/42/43): live workout heartbeat + provenance flags.
--
-- live_workouts: one row per user (PK user_id, upsert-overwritten) that the
-- watch heartbeats every ~5s while a workout is running, so the web Workout
-- tab can mirror it live. End AND Discard set status='ended' rather than
-- deleting — postgres_changes can't filter DELETE events, and the web treats
-- updated_at older than ~30s as a dead watch anyway.
create table public.live_workouts (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  workout_id uuid not null, -- pre-generated on the watch; matches the final climb_workouts.id
  status text not null default 'live' check (status in ('live','ended')),
  started_at timestamptz not null,
  hr real,
  attempt_count integer not null default 0,
  active_kcal real,
  elevation_gain_m real,
  climbing boolean not null default false, -- a manual attempt is open on the watch
  updated_at timestamptz not null default now()
);

alter table public.live_workouts enable row level security;
create policy "own live select" on public.live_workouts for select using (auth.uid() = user_id);
create policy "own live insert" on public.live_workouts for insert with check (auth.uid() = user_id);
create policy "own live update" on public.live_workouts for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own live delete" on public.live_workouts for delete using (auth.uid() = user_id);

alter publication supabase_realtime add table public.live_workouts;

-- Provenance: which device created the workout, and whether each attempt was
-- auto-detected (altimeter/motion state machine) or manually logged.
alter table public.climb_workouts
  add column source text not null default 'watch' check (source in ('watch','phone'));
alter table public.climb_attempts
  add column source text not null default 'auto' check (source in ('auto','manual'));

-- climb_attempts shipped without an update policy (insert/select/delete only);
-- editing attempts from the web needs it.
create policy "own attempts update" on public.climb_attempts
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Immutable auto-tracked badge for sessions (SL-43). The displayed type is
-- editable, so sessions.type='auto' can no longer be the marker; this column
-- is never touched by the edit UI. null = plain logged session.
alter table public.sessions
  add column workout_source text check (workout_source in ('watch','phone'));
update public.sessions set workout_source = 'watch' where type = 'auto';
