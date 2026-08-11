-- Slice 1 of #543: side applicability is exercise-specific, but the only
-- shared type is `TindeqSide` on individual recordings/presets, so every
-- surface must offer all four side choices for every exercise. `side_mode`
-- adds that policy to the SL-92 registry; a missing registry row still means
-- the default mode, same as the existing hidden/curve columns. Slice 2 wires
-- selectors to it, slice 3 the watch/protocol — this migration only adds the
-- data model.
alter table public.tindeq_tags
  add column side_mode text not null default 'unilateral_or_bilateral'
    check (side_mode in ('unilateral_or_bilateral', 'unilateral_only', 'bilateral_only', 'not_applicable'));

-- Carry side_mode across a rename, mirroring the existing "target row's
-- hidden state wins, old row is dropped" merge: only backfill side_mode onto
-- the target when it has no registry row of its own yet, so an explicitly-set
-- mode on a surviving target row is never clobbered.
create or replace function public.rename_tindeq_tag(old_name text, new_name text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  old_side_mode text;
begin
  new_name := trim(new_name);
  if new_name = '' then
    raise exception 'tag name cannot be empty';
  end if;
  if new_name = old_name then
    return;
  end if;
  select side_mode into old_side_mode from public.tindeq_tags where name = old_name;
  update public.tindeq_recordings set tag = new_name where tag = old_name;
  if old_side_mode is not null and not exists (
    select 1 from public.tindeq_tags where name = new_name
  ) then
    insert into public.tindeq_tags (name, side_mode) values (new_name, old_side_mode);
  end if;
  delete from public.tindeq_tags where name = old_name;
end;
$$;
