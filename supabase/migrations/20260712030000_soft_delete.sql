-- Soft delete for sessions and tindeq_recordings: "delete" sets deleted_at
-- instead of removing the row, so it can be recovered from a Trash view.
-- Existing delete RLS policies stay in place — they now back a separate
-- "delete forever" (purge) action instead of the everyday delete button.

alter table public.sessions add column deleted_at timestamptz;
alter table public.tindeq_recordings add column deleted_at timestamptz;

-- Partial indexes for the common "active rows" query shape used everywhere
-- outside the Trash view.
create index sessions_active_idx on public.sessions (user_id, date desc) where deleted_at is null;
create index tindeq_recordings_active_idx on public.tindeq_recordings (user_id, recorded_at desc) where deleted_at is null;

-- tindeq_recordings never had an update policy — soft delete is an update.
create policy "own recordings update" on public.tindeq_recordings for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
