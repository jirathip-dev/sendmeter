-- #942: merge same-day Tindeq sessions into ONE session, atomically.
--
-- History accumulates one `tindeq` session per guided protocol run (see the
-- companion #941 on keeping the gauge session open), so one day's work can be
-- spread over several entries. The History "Merge with…" action collapses a
-- user-selected same-day set into a single session:
--
--   * the SURVIVOR keeps its identity, its `date` and its phase. The app
--     picks it as the earliest-started session (from the groups' recording
--     timestamps — `sessions` carries no start column);
--   * every recording of every selected group is re-pointed to the
--     survivor's `group_id`;
--   * duration and note are rebuilt server-side from the post-move
--     recording set, so the row can never disagree with what it contains
--     ("N recordings · tag1, tag2", span = first start → last end, clamped
--     to the 1..600 `duration_min` bound — the same rule
--     `GaugeSessionDuration`/`GaugeSessionNote` apply in the app);
--   * RPE and `rpe_confirmed` come from the app: a re-predicted W'-depletion
--     RPE (`GaugeSessionRPE.predict`, which needs the device's fitted
--     curves) or, when any selected session already carried a
--     user-confirmed RPE, the latest confirmed one;
--   * the other sessions are soft-deleted (`deleted_at`), matching every
--     other session delete in this schema, so the merge stays as
--     recoverable as any single-session delete.
--
-- WHY A FUNCTION: the naive client sequence (re-point the recordings, then
-- delete the extra sessions) is not atomic. A failure between the two writes
-- leaves the recordings stamped with a group no live session references —
-- the orphaned-recordings state this RPC exists to make impossible. A
-- PL/pgSQL body IS one transaction: any exception rolls the re-point, the
-- survivor update and the deletes back together.
--
-- `security invoker` (matching `link_tindeq_recordings_to_session`, the
-- precedent for this shape): RLS on `sessions`/`tindeq_recordings` already
-- scopes every statement to the caller's own rows, so no elevated privilege
-- is needed or granted. That also makes the ownership guard structural: a
-- session id the caller does not own is invisible, so the row count cannot
-- match the requested set and the call fails closed. supabase/tests/
-- merge_tindeq_sessions.sql is the RED/GREEN proof (it switches to the
-- `authenticated` role for real, so RLS is actually exercised).
--
-- GUARDRAILS (the RPC is the authority; the app only mirrors them for UX):
--   * at least two distinct sessions, and the survivor among them;
--   * every requested session exists, is owned by the caller, and is live;
--   * every one is `type = 'tindeq'`;
--   * every one carries the SAME `date` — same stored local-day value, so
--     "same local day" is exact (Postgres has no notion of the caller's
--     zone; the app already stores local dates);
--   * the survivor's group is reused, never re-minted, when it has one.
--
-- IDEMPOTENT RETRY: a queued offline merge whose response was lost (app
-- killed after commit, before the queue entry was removed) retries the exact
-- same payload. When every non-survivor session is already soft-deleted the
-- function reports the survivor's current state instead of raising, so a
-- completed merge is never quarantined as a permanent failure.
--
-- Existing rows: none touched. This migration only adds a function.

create or replace function public.merge_tindeq_sessions(
  p_session_ids uuid[],
  p_survivor_id uuid,
  p_rpe numeric,
  p_rpe_confirmed boolean
)
returns table (
  group_id uuid,
  duration_min integer,
  recording_count integer,
  note text
)
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_ids uuid[];
  v_count integer;
  v_distinct_dates integer;
  v_non_tindeq integer;
  v_deleted integer;
  v_non_survivor_deleted integer;
  v_target_group uuid;
  v_start timestamptz;
  v_end timestamptz;
  v_duration integer;
  v_note text;
  v_tags text;
  v_recording_count integer;
begin
  if auth.uid() is null then
    raise exception 'merge rejected: not authenticated';
  end if;

  -- The plan's RPE is always a concrete banked value (a fresh prediction or a
  -- kept confirmed one); a missing one is a client bug, not a default.
  if p_rpe is null then
    raise exception 'merge rejected: rpe required';
  end if;

  select array_agg(distinct x)
    into v_ids
    from unnest(p_session_ids) as x
   where x is not null;

  if coalesce(array_length(v_ids, 1), 0) < 2 then
    raise exception 'merge rejected: at least two sessions are required';
  end if;
  if p_survivor_id is null or not (p_survivor_id = any (v_ids)) then
    raise exception 'merge rejected: survivor must be one of the merged sessions';
  end if;

  -- Lock every selected row BEFORE reading anything (RLS scopes this to the
  -- caller's rows). Two concurrent merges over overlapping sets then
  -- serialize here instead of each minting its own outcome; a foreign or
  -- already-purged id simply is not there to lock or read below.
  perform s.id from public.sessions s where s.id = any (v_ids) for update;

  select count(*),
         count(distinct s.date),
         count(*) filter (where s.type <> 'tindeq'),
         count(*) filter (where s.deleted_at is not null)
    into v_count, v_distinct_dates, v_non_tindeq, v_deleted
    from public.sessions s
   where s.id = any (v_ids);

  -- Fail closed when any requested id is not a live caller-owned row: under
  -- RLS a foreign session is invisible, so a count mismatch IS the
  -- cross-account rejection (see the test's RED proof), and it also covers
  -- an id that never existed or was purged.
  if v_count <> array_length(v_ids, 1) then
    raise exception 'merge rejected: session not found';
  end if;
  if v_non_tindeq > 0 then
    raise exception 'merge rejected: only tindeq sessions can be merged';
  end if;
  if v_distinct_dates <> 1 then
    raise exception 'merge rejected: sessions must share one local day';
  end if;
  if v_deleted = v_count then
    raise exception 'merge rejected: sessions already deleted';
  end if;

  -- The survivor adopts/keeps a group id. UPDATE ... RETURNING takes the row
  -- lock itself (see #490's F1 for why a bare SELECT is not enough), so a
  -- concurrent merge sharing this survivor waits and then observes the
  -- committed group instead of minting a competing one.
  update public.sessions s
     set group_id = coalesce(s.group_id, gen_random_uuid())
   where s.id = p_survivor_id
  returning s.group_id into v_target_group;

  if not found then
    raise exception 'merge rejected: session not found';
  end if;

  -- Lost-response retry: everything except the survivor is already deleted,
  -- so this exact merge has been applied. Report the survivor's current
  -- state as success instead of quarantining a completed write.
  select count(*) filter (where s.deleted_at is not null)
    into v_non_survivor_deleted
    from public.sessions s
   where s.id = any (v_ids) and s.id <> p_survivor_id;

  if v_non_survivor_deleted = array_length(v_ids, 1) - 1 then
    select s.duration_min, s.note
      into v_duration, v_note
      from public.sessions s
     where s.id = p_survivor_id;
    select count(*)
      into v_recording_count
      from public.tindeq_recordings r
     where r.group_id = v_target_group
       and r.deleted_at is null;
    return query select v_target_group, v_duration, v_recording_count, v_note;
    return;
  end if;

  -- Re-point the recordings of every selected group — INCLUDING soft-deleted
  -- ones, so a later Trash restore lands inside the merged session instead of
  -- a group no session references. `is distinct from` keeps the survivor's
  -- own recordings untouched by the update.
  update public.tindeq_recordings r
     set group_id = v_target_group
   where r.group_id is not null
     and r.group_id is distinct from v_target_group
     and r.group_id in (
           select s.group_id
             from public.sessions s
            where s.id = any (v_ids)
              and s.group_id is not null
         );

  -- Duration + note are rebuilt from the recording set that now belongs to
  -- the survivor (live rows only — a trashed recording is not part of the
  -- effort), mirroring GaugeSessionDuration.spanMinutes / GaugeSessionNote.
  select count(*),
         min(r.recorded_at),
         max(r.recorded_at + (r.duration_ms || ' milliseconds')::interval)
    into v_recording_count, v_start, v_end
    from public.tindeq_recordings r
   where r.group_id = v_target_group
     and r.deleted_at is null;

  -- Tags in first-appearance order over the recordings sorted by
  -- (recorded_at, id) — exactly what GaugeSessionNote.build produces from
  -- the app's chronologically sorted list.
  select string_agg(t.tag, ', ' order by t.recorded_at, t.id)
    into v_tags
    from (
      select distinct on (r.tag) r.tag, r.recorded_at, r.id
        from public.tindeq_recordings r
       where r.group_id = v_target_group
         and r.deleted_at is null
         and r.tag <> ''
       order by r.tag, r.recorded_at, r.id
    ) t;

  if v_recording_count > 0 then
    v_duration := greatest(
      1,
      least(
        600,
        round((extract(epoch from (v_end - v_start)) * 1000 / 60000.0)::numeric)::integer
      )
    );
  else
    -- Nothing to measure (a merge of sessions with no recordings): keep the
    -- survivor's own duration rather than inventing one.
    select s.duration_min into v_duration from public.sessions s where s.id = p_survivor_id;
  end if;

  v_note := v_recording_count::text
    || case when v_recording_count = 1 then ' recording' else ' recordings' end;
  if v_tags is not null and v_tags <> '' then
    v_note := v_note || ' · ' || v_tags;
  end if;

  update public.sessions s
     set duration_min = v_duration,
         rpe = p_rpe,
         rpe_confirmed = coalesce(p_rpe_confirmed, false),
         note = v_note
   where s.id = p_survivor_id;

  update public.sessions s
     set deleted_at = now()
   where s.id = any (v_ids)
     and s.id <> p_survivor_id
     and s.deleted_at is null;

  return query select v_target_group, v_duration, v_recording_count, v_note;
end;
$$;

revoke execute on function public.merge_tindeq_sessions(uuid[], uuid, numeric, boolean)
  from public, anon;
grant execute on function public.merge_tindeq_sessions(uuid[], uuid, numeric, boolean)
  to authenticated;
