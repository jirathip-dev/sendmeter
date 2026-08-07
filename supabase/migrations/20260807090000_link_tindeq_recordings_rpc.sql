-- #490: linkRecordingsToSession performed three separate, non-transactional
-- writes (mint+set sessions.group_id, regroup the recordings, recompute
-- sessions.duration_min) — a failure on the 2nd or 3rd write left the first
-- committed on its own, stranding the user in a half-transformed state (the
-- session pointing at a group with none/some of the intended recordings, or
-- grouped correctly but with a stale duration). #487 removed one cause of
-- write 3 failing (an unclamped duration hitting the duration_min check) but
-- not the underlying non-atomicity.
--
-- This function does all three writes inside one transaction (a PL/pgSQL
-- function body IS one transaction — any exception anywhere inside rolls the
-- whole call back, proven against a scratch Postgres outside this repo: a
-- forced mid-function failure left both `sessions.group_id` and every
-- `tindeq_recordings.group_id` completely unchanged, vs. the pre-fix
-- three-statement version which left the session re-grouped with zero
-- recordings actually joined to it).
--
-- `security invoker` (matching `rename_tindeq_tag`, the existing precedent
-- for this shape) — RLS on `sessions`/`tindeq_recordings` already scopes
-- every statement inside to the caller's own rows, so no elevated privilege
-- is needed or granted. A session id the caller doesn't own is invisible to
-- the initial UPDATE (RLS), so it raises 'session not found' rather than
-- silently touching someone else's row; recording ids the caller doesn't own
-- are silently skipped by the regroup UPDATE, exactly like the `.in(...)`
-- batch update it replaces.
--
-- The group_id read-then-write is a single `UPDATE ... RETURNING`, not a
-- separate `SELECT` followed by a conditional `UPDATE` (review finding F1):
-- a bare SELECT takes no row lock, so two concurrent calls for the same
-- ungrouped session could both read group_id IS NULL, both mint their own
-- UUID, and the second UPDATE would silently win — leaving the first call's
-- recordings stamped with a group_id no session references (reproduced
-- against the pre-fix version of this function with a widened window; both
-- calls reported success, which is worse than the error case #490 fixed,
-- since nothing surfaced). `UPDATE ... WHERE id = p_session_id` takes the
-- row lock itself: a second concurrent call blocks on the first's lock,
-- then re-reads the now-committed group_id via `coalesce`, so it joins the
-- same group instead of minting a competing one.
--
-- Duration recompute mirrors `computeGroupDurationMin`
-- (src/lib/duration.ts): span from the earliest recording's start to the
-- latest recording's end, clamped to the `duration_min between 1 and 600`
-- check constraint. Only run for `type = 'tindeq'` sessions — a manually
-- logged session's duration is a user-typed value and must not be
-- clobbered by a few attached gauge reps (mirrors `linkRecordingsToSession`'s
-- existing comment).
--
-- Existing rows: none touched. This migration only adds a new function;
-- it performs no DML.
create or replace function public.link_tindeq_recordings_to_session(
  p_session_id uuid,
  p_recording_ids uuid[]
)
returns table (group_id uuid, duration_min integer)
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_group_id uuid;
  v_session_type text;
  v_start timestamptz;
  v_end timestamptz;
  v_span_ms double precision;
  v_duration_min integer;
begin
  if p_recording_ids is null or array_length(p_recording_ids, 1) is null then
    return;
  end if;

  update sessions s
  set group_id = coalesce(s.group_id, gen_random_uuid())
  where s.id = p_session_id
  returning s.group_id, s.type into v_group_id, v_session_type;

  if not found then
    raise exception 'session not found';
  end if;

  update tindeq_recordings
  set group_id = v_group_id
  where id = any(p_recording_ids);

  if v_session_type = 'tindeq' then
    select min(r.recorded_at), max(r.recorded_at + (r.duration_ms || ' milliseconds')::interval)
    into v_start, v_end
    from tindeq_recordings r
    where r.group_id = v_group_id and r.deleted_at is null;

    if v_start is not null then
      v_span_ms := extract(epoch from (v_end - v_start)) * 1000;
      v_duration_min := greatest(1, least(600, round((v_span_ms / 60000.0)::numeric)::integer));
      update sessions s
      set duration_min = v_duration_min
      where s.group_id = v_group_id and s.deleted_at is null;
    end if;
  end if;

  return query select v_group_id, v_duration_min;
end;
$$;

revoke execute on function public.link_tindeq_recordings_to_session(uuid, uuid[]) from public, anon;
grant execute on function public.link_tindeq_recordings_to_session(uuid, uuid[]) to authenticated;
