-- #778: hard purges are observable by incremental native clients.
--
-- A deleted_at tombstone is enough for the normal Trash move, but "Delete
-- Permanently" removes the row and therefore cannot appear in an
-- updated_at-bounded delta. Keep one monotonic, per-user invalidation counter
-- instead of one journal row per purge. Native clients compare the counter
-- with their account-scoped cache boundary and run an authoritative full
-- reconcile for sessions + recordings when it changes.

create table public.sync_purge_generations (
  user_id uuid primary key references auth.users(id) on delete cascade,
  generation bigint not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.sync_purge_generations enable row level security;

create policy "own purge generation select"
on public.sync_purge_generations
for select using (auth.uid() = user_id);

-- The trigger is SECURITY DEFINER so it also observes hard deletes made by
-- security-definer account cleanup and by older clients. It only stores the
-- bounded counter; the deleted row itself remains permanently gone.
create or replace function public.record_hard_delete_sync_generation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Account deletion cascades through these tables while the parent auth row
  -- is being removed. Do not create a generation row that the same cascade
  -- cannot satisfy; ordinary purges still take the incrementing path below.
  if not exists (select 1 from auth.users where id = old.user_id) then
    return old;
  end if;

  insert into public.sync_purge_generations (user_id, generation, updated_at)
  values (old.user_id, 1, now())
  on conflict (user_id) do update set
    generation = public.sync_purge_generations.generation + 1,
    updated_at = excluded.updated_at;
  return old;
end;
$$;

revoke execute on function public.record_hard_delete_sync_generation() from public, anon, authenticated;

drop trigger if exists sessions_record_hard_delete_sync_generation on public.sessions;
create trigger sessions_record_hard_delete_sync_generation
after delete on public.sessions
for each row execute function public.record_hard_delete_sync_generation();

drop trigger if exists recordings_record_hard_delete_sync_generation on public.tindeq_recordings;
create trigger recordings_record_hard_delete_sync_generation
after delete on public.tindeq_recordings
for each row execute function public.record_hard_delete_sync_generation();

-- Only Trash rows may be deleted through the ordinary table API. The RPCs
-- below also enforce this condition explicitly, so a restore racing a retry
-- can never turn "Delete permanently" into an active-row delete.
drop policy if exists "own sessions delete" on public.sessions;
create policy "own sessions delete"
on public.sessions
for delete using (auth.uid() = user_id and deleted_at is not null);

drop policy if exists "own recordings delete" on public.tindeq_recordings;
create policy "own recordings delete"
on public.tindeq_recordings
for delete using (auth.uid() = user_id and deleted_at is not null);

-- Idempotent, account-scoped purge entry points. The trigger above is the
-- single generation-bump mechanism, so direct legacy deletes and these RPCs
-- converge through exactly the same signal. `false` means the row was already
-- gone (or was restored), which is a successful no-op for a retried purge.
create or replace function public.purge_session(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  delete from public.sessions
  where id = p_id
    and user_id = auth.uid()
    and deleted_at is not null;
  return found;
end;
$$;

create or replace function public.purge_recording(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  delete from public.tindeq_recordings
  where id = p_id
    and user_id = auth.uid()
    and deleted_at is not null;
  return found;
end;
$$;

revoke execute on function public.purge_session(uuid) from public, anon;
grant execute on function public.purge_session(uuid) to authenticated;
revoke execute on function public.purge_recording(uuid) from public, anon;
grant execute on function public.purge_recording(uuid) to authenticated;

grant select on public.sync_purge_generations to authenticated;
