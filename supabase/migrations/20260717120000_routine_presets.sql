-- Routine presets: user-defined guided routines — an ordered list of timed
-- steps (label + seconds). Drives the Workout tab's routine timer (warm-ups,
-- conditioning circuits, mobility flows, …). Synced via Supabase so web and
-- iPhone share them, mirroring tindeq_presets.
create table public.routine_presets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null default '',
  -- [{ "label": string, "detail"?: string, "s": number }, …] — shape is
  -- enforced client-side; the check just guards the container type.
  steps jsonb not null check (jsonb_typeof(steps) = 'array'),
  created_at timestamptz not null default now()
);
create index routine_presets_user_idx on public.routine_presets (user_id, created_at desc);

alter table public.routine_presets enable row level security;
create policy "own routine presets select" on public.routine_presets for select using (auth.uid() = user_id);
create policy "own routine presets insert" on public.routine_presets for insert with check (auth.uid() = user_id);
create policy "own routine presets update" on public.routine_presets for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own routine presets delete" on public.routine_presets for delete using (auth.uid() = user_id);
