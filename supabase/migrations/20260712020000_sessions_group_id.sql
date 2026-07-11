-- Link a training-log session to the Tindeq gauge session (recording group)
-- it was created from, so History can expand into the group's recordings.
alter table public.sessions add column group_id uuid;
create index sessions_group_idx on public.sessions (group_id) where group_id is not null;
