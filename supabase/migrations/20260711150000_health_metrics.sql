-- Daily recovery metrics computed on-watch from HealthKit + own ACWR.
-- One row per user per local day, idempotent upsert on (user_id, date).
-- readiness/zone are nullable: a row can carry raw metrics even when
-- there's not enough baseline history to score.

create table public.health_metrics (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date date not null,
  hrv_sdnn_ms real,
  resting_hr real,
  sleep_hours real,
  body_mass_kg real,
  readiness integer check (readiness between 0 and 100),
  zone text,
  computed_at timestamptz not null default now(),
  primary key (user_id, date)
);

alter table public.health_metrics enable row level security;
create policy "own health select" on public.health_metrics for select using (auth.uid() = user_id);
create policy "own health insert" on public.health_metrics for insert with check (auth.uid() = user_id);
create policy "own health update" on public.health_metrics for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
