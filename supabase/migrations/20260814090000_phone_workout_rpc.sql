-- #615: insertPhoneWorkout performed three separate, non-transactional writes
-- (sessions, climb_workouts, climb_attempts) and the client waited for all
-- three before publishing success. A mid-flight failure left the session
-- without its workout, and nothing could be retried idempotently (all three
-- ids were DB-minted). This function replaces all three inserts with ONE
-- transaction: either the whole relational bundle commits, or none of it.
--
-- The client mints the session + workout ids and replays them on retry; the
-- function returns the canonical session row for an already-committed id
-- (idempotent replay) instead of inserting a second bundle, so a retried
-- save after a lost response or a process restart reconciles exactly once.
--
-- `security invoker` (matching `link_tindeq_recordings_to_session`, the
-- existing precedent for this shape) — RLS on `sessions`/`climb_workouts`/
-- `climb_attempts` scopes every statement inside to the caller's own rows,
-- and the `user_id default auth.uid()` columns attribute the rows to the
-- calling account with no explicit stamp needed. A replay of an id the caller
-- does not own is invisible to the existence check (RLS), so it falls through
-- to the INSERT and fails on the PK rather than silently reading someone
-- else's row.
--
-- The unique-violation handler is the concurrent-duplicate case: two retries
-- of the same bundle race the existence check, the loser's INSERT blocks on
-- the winner's PK lock and then raises 23505 — inside the exception block the
-- subtransaction's partial work is rolled back, so re-selecting by
-- p_session_id sees the winner's committed canonical row and returns it.
-- If the id genuinely doesn't exist (a colliding p_workout_id with a new
-- session id — a caller bug), the re-select finds nothing and re-raises.
--
-- Existing rows: none touched. This migration only adds a new function;
-- it performs no DML.
create or replace function public.create_phone_workout(
  p_session_id uuid,
  p_workout_id uuid,
  p_date date,
  p_type text,
  p_type_label text,
  p_duration_min integer,
  p_rpe numeric,
  p_note text,
  p_phase text,
  p_started_at timestamptz,
  p_ended_at timestamptz,
  p_attempts jsonb default '[]'::jsonb
)
returns table (
  id uuid,
  date date,
  type text,
  type_label text,
  duration_min integer,
  rpe numeric,
  rpe_confirmed boolean,
  load integer,
  note text,
  phase text,
  group_id uuid,
  workout_source text
)
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_exists boolean;
begin
  -- `returns table(id uuid, ...)` puts the out-param name in scope, so the
  -- unqualified `id` here would be ambiguous (42702) — always qualify.
  select exists(select 1 from sessions where sessions.id = p_session_id) into v_exists;
  if v_exists then
    return query
      select s.id, s.date, s.type, s.type_label, s.duration_min,
             s.rpe, s.rpe_confirmed, s.load, s.note, s.phase, s.group_id,
             s.workout_source
      from sessions s
      where s.id = p_session_id;
    return;
  end if;

  insert into sessions (
    id, date, type, type_label, duration_min, rpe, note, phase,
    workout_source, rpe_confirmed
  )
  values (
    p_session_id, p_date, p_type, p_type_label, p_duration_min, p_rpe,
    p_note, p_phase, 'phone',
    -- Unconfirmed until the user edits it away from the auto-save default
    -- (issue #114) — mirrors the sequential insert it replaces.
    false
  );

  insert into climb_workouts (
    id, started_at, ended_at, attempts_detected, attempts_confirmed,
    rpe_confirmed, session_id, source
  )
  values (
    p_workout_id, p_started_at, p_ended_at, 0,
    coalesce(jsonb_array_length(p_attempts), 0), p_rpe, p_session_id, 'phone'
  );

  if p_attempts is not null and jsonb_array_length(p_attempts) > 0 then
    insert into climb_attempts (workout_id, started_at, duration_s, elevation_gain_m, source)
    select p_workout_id,
           (a ->> 'started_at')::timestamptz,
           (a ->> 'duration_s')::numeric,
           0,
           'manual'
    from jsonb_array_elements(p_attempts) as a;
  end if;

  return query
    select s.id, s.date, s.type, s.type_label, s.duration_min,
           s.rpe, s.rpe_confirmed, s.load, s.note, s.phase, s.group_id,
           s.workout_source
    from sessions s
    where s.id = p_session_id;
exception
  when unique_violation then
    return query
      select s.id, s.date, s.type, s.type_label, s.duration_min,
             s.rpe, s.rpe_confirmed, s.load, s.note, s.phase, s.group_id,
             s.workout_source
      from sessions s
      where s.id = p_session_id;
    if not found then
      raise;
    end if;
end;
$$;

revoke execute on function public.create_phone_workout(uuid, uuid, date, text, text, integer, numeric, text, text, timestamptz, timestamptz, jsonb) from public, anon;
grant execute on function public.create_phone_workout(uuid, uuid, date, text, text, integer, numeric, text, text, timestamptz, timestamptz, jsonb) to authenticated;
