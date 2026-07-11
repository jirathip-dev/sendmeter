-- Phase history: one row per contiguous stretch in a training phase.
-- Invariant: exactly one open period (ended_on is null) per user, enforced
-- by a partial unique index. user_settings.current_phase stays authoritative
-- for the watch app (Repo.fetchCurrentPhase) and is kept in sync on switch.

create table public.phase_periods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  phase text not null,
  started_on date not null,
  ended_on date,
  created_at timestamptz not null default now(),
  check (ended_on is null or ended_on >= started_on)
);
create index phase_periods_user_started_idx on public.phase_periods (user_id, started_on desc);
create unique index phase_periods_one_open_idx on public.phase_periods (user_id) where ended_on is null;

alter table public.phase_periods enable row level security;
create policy "own periods select" on public.phase_periods for select using (auth.uid() = user_id);
create policy "own periods insert" on public.phase_periods for insert with check (auth.uid() = user_id);
create policy "own periods update" on public.phase_periods for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own periods delete" on public.phase_periods for delete using (auth.uid() = user_id);

-- Backfill: one open period per existing user from current settings.
insert into public.phase_periods (user_id, phase, started_on)
select user_id, current_phase, phase_start_date
from public.user_settings;
