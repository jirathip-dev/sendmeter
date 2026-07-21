-- SL-92: tag management (rename + hide). Tags stay DENORMALIZED as the text
-- `tindeq_recordings.tag` — the grouping key everywhere, written directly by
-- the watch and web without a lookup — so this table is a lightweight
-- per-user REGISTRY for metadata (currently just the hidden flag), not a
-- foreign-key parent. A tag needs a row here only once it's hidden; visible
-- tags are derived from distinct recording tags as before.
create table public.tindeq_tags (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  unique (user_id, name)
);

create index tindeq_tags_user_idx on public.tindeq_tags (user_id);

alter table public.tindeq_tags enable row level security;
create policy "own tags select" on public.tindeq_tags for select using (auth.uid() = user_id);
create policy "own tags insert" on public.tindeq_tags for insert with check (auth.uid() = user_id);
create policy "own tags update" on public.tindeq_tags for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own tags delete" on public.tindeq_tags for delete using (auth.uid() = user_id);

-- Rename a tag across the whole dataset in one transaction: repoint every
-- recording, then drop any stale registry row (a renamed tag becomes visible
-- again; if the new name already has a row its hidden state wins). security
-- invoker — the caller's RLS scopes both statements to their own rows.
create or replace function public.rename_tindeq_tag(old_name text, new_name text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  new_name := trim(new_name);
  if new_name = '' then
    raise exception 'tag name cannot be empty';
  end if;
  if new_name = old_name then
    return;
  end if;
  update public.tindeq_recordings set tag = new_name where tag = old_name;
  delete from public.tindeq_tags where name = old_name;
end;
$$;
