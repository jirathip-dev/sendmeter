-- Tindeq protocol presets: user-defined hang protocols (hold / reps / sets /
-- rests) that drive the guided timer in the fullscreen gauge. Synced via
-- Supabase so web and iPhone share them.
create table public.tindeq_presets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null default '',
  hold_s integer not null check (hold_s between 1 and 600),
  reps integer not null check (reps between 1 and 50),
  sets integer not null check (sets between 1 and 20),
  rest_reps_s integer not null check (rest_reps_s between 0 and 600),
  rest_sets_s integer not null check (rest_sets_s between 0 and 1200),
  created_at timestamptz not null default now()
);
create index tindeq_presets_user_idx on public.tindeq_presets (user_id, created_at desc);

alter table public.tindeq_presets enable row level security;
create policy "own presets select" on public.tindeq_presets for select using (auth.uid() = user_id);
create policy "own presets insert" on public.tindeq_presets for insert with check (auth.uid() = user_id);
create policy "own presets update" on public.tindeq_presets for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own presets delete" on public.tindeq_presets for delete using (auth.uid() = user_id);
