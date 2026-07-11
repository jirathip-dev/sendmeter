-- Watch-tracked climbing workouts + auto-detected boulder attempts.
-- Written by the watchOS app; confirmed workouts also create a sessions row
-- (type 'auto') so web ACWR/history work unchanged.

create table public.climb_workouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  avg_hr real,
  max_hr real,
  active_kcal real,
  elevation_gain_m real not null default 0,
  attempts_detected integer not null default 0,
  attempts_confirmed integer not null default 0,
  rpe_predicted numeric(3,1),
  rpe_confirmed integer check (rpe_confirmed between 1 and 10),
  session_id uuid references public.sessions(id) on delete set null,
  raw jsonb, -- 1Hz debug trace [[t_s, alt_m, motion_rms, hr], ...] for tuning/ML
  created_at timestamptz not null default now(),
  check (ended_at >= started_at)
);
create index climb_workouts_user_time_idx on public.climb_workouts (user_id, started_at desc);
create index climb_workouts_session_idx on public.climb_workouts (session_id);

create table public.climb_attempts (
  id uuid primary key default gen_random_uuid(),
  workout_id uuid not null references public.climb_workouts(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  started_at timestamptz not null,
  duration_s real not null check (duration_s > 0),
  elevation_gain_m real not null,
  avg_hr real,
  peak_hr real,
  motion_intensity real, -- mean |userAcceleration| RMS in g during the attempt
  effort_score real,     -- 0..10, formula versioned in the watch app's Tunables
  created_at timestamptz not null default now()
);
create index climb_attempts_workout_idx on public.climb_attempts (workout_id);
create index climb_attempts_user_time_idx on public.climb_attempts (user_id, started_at desc);

alter table public.climb_workouts enable row level security;
alter table public.climb_attempts enable row level security;

create policy "own workouts select" on public.climb_workouts for select using (auth.uid() = user_id);
create policy "own workouts insert" on public.climb_workouts for insert with check (auth.uid() = user_id);
create policy "own workouts update" on public.climb_workouts for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own workouts delete" on public.climb_workouts for delete using (auth.uid() = user_id);

create policy "own attempts select" on public.climb_attempts for select using (auth.uid() = user_id);
create policy "own attempts insert" on public.climb_attempts for insert with check (auth.uid() = user_id);
create policy "own attempts delete" on public.climb_attempts for delete using (auth.uid() = user_id);
