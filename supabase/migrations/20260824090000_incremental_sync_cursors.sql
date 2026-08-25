-- #747 slice 3: row versioning + soft-delete tombstones for incremental
-- cache reconcile.
--
-- These columns are additive with defaults, so existing clients keep working
-- unchanged. New native clients use updated_at as a per-row cursor and
-- deleted_at as an explicit remote tombstone, replacing full-refetch
-- reconciliation for foreground refreshes.

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

alter table public.sessions
  add column updated_at timestamptz not null default now();
alter table public.phase_periods
  add column updated_at timestamptz not null default now(),
  add column deleted_at timestamptz;
alter table public.health_metrics
  add column updated_at timestamptz not null default now();
alter table public.tindeq_recordings
  add column updated_at timestamptz not null default now();
alter table public.tindeq_presets
  add column updated_at timestamptz not null default now(),
  add column deleted_at timestamptz;
alter table public.routine_presets
  add column updated_at timestamptz not null default now(),
  add column deleted_at timestamptz;
alter table public.climb_workouts
  add column updated_at timestamptz not null default now();
alter table public.climb_attempts
  add column updated_at timestamptz not null default now();
alter table public.tindeq_tags
  add column updated_at timestamptz not null default now();

-- `user_settings` already has the column, but native/web writes may supply
-- their own value (and older clients omit it), so stamp it like every other
-- cache-read table for a reliable cursor.
create trigger user_settings_set_updated_at
before insert or update on public.user_settings
for each row execute function public.set_updated_at();

create trigger sessions_set_updated_at
before insert or update on public.sessions
for each row execute function public.set_updated_at();

create trigger phase_periods_set_updated_at
before insert or update on public.phase_periods
for each row execute function public.set_updated_at();

create trigger health_metrics_set_updated_at
before insert or update on public.health_metrics
for each row execute function public.set_updated_at();

create trigger tindeq_recordings_set_updated_at
before insert or update on public.tindeq_recordings
for each row execute function public.set_updated_at();

create trigger tindeq_presets_set_updated_at
before insert or update on public.tindeq_presets
for each row execute function public.set_updated_at();

create trigger routine_presets_set_updated_at
before insert or update on public.routine_presets
for each row execute function public.set_updated_at();

create trigger climb_workouts_set_updated_at
before insert or update on public.climb_workouts
for each row execute function public.set_updated_at();

create trigger climb_attempts_set_updated_at
before insert or update on public.climb_attempts
for each row execute function public.set_updated_at();

create trigger tindeq_tags_set_updated_at
before insert or update on public.tindeq_tags
for each row execute function public.set_updated_at();

-- The one-open-phase invariant must only consider active periods.
drop index if exists phase_periods_one_open_idx;
create unique index phase_periods_one_open_idx
on public.phase_periods (user_id)
where ended_on is null and deleted_at is null;

-- Delta queries are per-user + updated_at; keep them off full table scans.
create index sessions_updated_at_idx on public.sessions (user_id, updated_at);
create index phase_periods_updated_at_idx on public.phase_periods (user_id, updated_at);
create index health_metrics_updated_at_idx on public.health_metrics (user_id, updated_at);
create index tindeq_recordings_updated_at_idx on public.tindeq_recordings (user_id, updated_at);
create index tindeq_presets_updated_at_idx on public.tindeq_presets (user_id, updated_at);
create index routine_presets_updated_at_idx on public.routine_presets (user_id, updated_at);
create index climb_workouts_updated_at_idx on public.climb_workouts (user_id, updated_at);
create index climb_attempts_updated_at_idx on public.climb_attempts (user_id, updated_at);
create index tindeq_tags_updated_at_idx on public.tindeq_tags (user_id, updated_at);
