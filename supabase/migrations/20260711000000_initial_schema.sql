-- Send Log initial schema: sessions, user settings, Tindeq recordings.
-- All tables are per-user with own-rows-only RLS.

create table public.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date date not null,
  type text not null,
  type_label text not null,
  duration_min integer not null check (duration_min between 1 and 600),
  rpe integer not null check (rpe between 1 and 10),
  load integer generated always as (duration_min * rpe) stored,
  note text not null default '',
  phase text not null,
  created_at timestamptz not null default now()
);
create index sessions_user_date_idx on public.sessions (user_id, date desc, created_at desc);

create table public.user_settings (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  current_phase text not null default 'capacity',
  phase_start_date date not null default current_date,
  updated_at timestamptz not null default now()
);

-- samples is jsonb [[t_ms, kg], ...]: one row per recording, always read whole,
-- ~40-60KB at 80Hz for a 30s pull — normalized sample rows would add cost with
-- no query benefit.
create table public.tindeq_recordings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  recorded_at timestamptz not null default now(),
  duration_ms integer not null check (duration_ms > 0),
  peak_kg real not null,
  avg_kg real not null,
  sample_count integer not null,
  note text not null default '',
  samples jsonb not null
);
create index tindeq_recordings_user_time_idx on public.tindeq_recordings (user_id, recorded_at desc);

alter table public.sessions enable row level security;
alter table public.user_settings enable row level security;
alter table public.tindeq_recordings enable row level security;

create policy "own sessions select" on public.sessions for select using (auth.uid() = user_id);
create policy "own sessions insert" on public.sessions for insert with check (auth.uid() = user_id);
create policy "own sessions update" on public.sessions for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own sessions delete" on public.sessions for delete using (auth.uid() = user_id);

create policy "own settings select" on public.user_settings for select using (auth.uid() = user_id);
create policy "own settings insert" on public.user_settings for insert with check (auth.uid() = user_id);
create policy "own settings update" on public.user_settings for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own recordings select" on public.tindeq_recordings for select using (auth.uid() = user_id);
create policy "own recordings insert" on public.tindeq_recordings for insert with check (auth.uid() = user_id);
create policy "own recordings delete" on public.tindeq_recordings for delete using (auth.uid() = user_id);
