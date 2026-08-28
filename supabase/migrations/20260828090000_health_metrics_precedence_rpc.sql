-- #802 AC4: dual-source precedence enforced ATOMICALLY at the server.
--
-- Both the watch and the iPhone write public.health_metrics for the same
-- (user_id, date). A client that fetches the row, does slow work, and then
-- upserts can clobber a rival write that landed in between
-- (last-write-wins flapping). This single RPC runs Guy's locked precedence
-- rule (2026-08-25) inside ONE transaction against the LIVE row:
--
--   * watch wins when the row for the date is stale/empty;
--   * phone wins whenever it carries a fresh, non-empty row;
--   * an empty candidate (no biometric) is discarded and never writes,
--     so a source-less pass can't clobber the other source's row.
--
-- Freshness is the same deterministic rule as the client policy: the
-- existing row's computed_at must fall on the same LOCAL day as the
-- candidate's computed_at, evaluated in the caller's p_timezone. This is
-- explicit because Postgres has no notion of the user's zone.
--
-- The #109 keep-score semantics carry through: a candidate that omits
-- readiness/zone/computed_at (nil) coalesce-updates only the biometrics and
-- leaves the existing score/timestamp untouched.
--
-- Idempotent on (user_id, date) — one row per user per day, never a
-- duplicate. `security invoker` (matching create_phone_workout) keeps every
-- statement inside scoped by RLS: the `with check (auth.uid() = user_id)`
-- insert/update guard fails closed if a caller stamps another account.
create or replace function public.upsert_health_metrics_with_precedence(
  p_user_id uuid,
  p_date date,
  p_hrv_sdnn_ms real,
  p_resting_hr real,
  p_sleep_hours real,
  p_sleep_deep_hours real,
  p_sleep_rem_hours real,
  p_body_mass_kg real,
  p_resp_rate_bpm real,
  p_readiness integer,
  p_zone text,
  p_computed_at timestamptz,
  p_writer text,
  p_timezone text
)
returns table (
  decision text,
  date date,
  readiness integer,
  zone text,
  computed_at timestamptz
)
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_existing public.health_metrics%rowtype;
  v_has_source boolean;
  v_writer text;
begin
  -- The RETURNS TABLE output columns (date/readiness/zone/computed_at) are
  -- in scope like vars, so every table column must be QUALIFIED below.
  v_has_source := p_hrv_sdnn_ms is not null
    or p_resting_hr is not null
    or p_sleep_hours is not null
    or p_sleep_deep_hours is not null
    or p_sleep_rem_hours is not null
    or p_body_mass_kg is not null
    or p_resp_rate_bpm is not null;

  -- Never persist an empty compute (#801's no-source-day invariant,
  -- enforced server-side so no client can clobber through it).
  if not v_has_source then
    return query
      select 'discarded'::text, p_date, null::integer, null::text, null::timestamptz;
    return;
  end if;

  -- Lock the live row so the decide and the write are one decision.
  select *
    into v_existing
    from public.health_metrics h
   where h.user_id = p_user_id and h.date = p_date
   for update;

  v_writer := lower(coalesce(p_writer, ''));

  if v_writer = 'watch'
     and found
     and (v_existing.hrv_sdnn_ms is not null
          or v_existing.resting_hr is not null
          or v_existing.sleep_hours is not null
          or v_existing.sleep_deep_hours is not null
          or v_existing.sleep_rem_hours is not null
          or v_existing.body_mass_kg is not null
          or v_existing.resp_rate_bpm is not null)
     and v_existing.computed_at is not null
     and ((v_existing.computed_at at time zone p_timezone)::date
          = (p_computed_at at time zone p_timezone)::date) then
    -- A fresh, non-empty row already owns the date: the watch must not
    -- touch it (deterministic winner, no flapping).
    return query
      select 'retained'::text, h.date, h.readiness, h.zone, h.computed_at
      from public.health_metrics h
      where h.user_id = p_user_id and h.date = p_date;
    return;
  end if;
  insert into public.health_metrics (
    user_id, date, hrv_sdnn_ms, resting_hr, sleep_hours, sleep_deep_hours,
    sleep_rem_hours, body_mass_kg, resp_rate_bpm, readiness, zone, computed_at
  ) values (
    p_user_id, p_date, p_hrv_sdnn_ms, p_resting_hr, p_sleep_hours,
    p_sleep_deep_hours, p_sleep_rem_hours, p_body_mass_kg, p_resp_rate_bpm,
    -- An omitting-readiness candidate (nil readiness/zone/computed_at) keeps
    -- the existing row's score + timestamp; a fresh insert with no existing
    -- row defaults computed_at to now() (the pre-#109 default semantics).
    coalesce(p_readiness, v_existing.readiness),
    coalesce(p_zone, v_existing.zone),
    coalesce(p_computed_at, v_existing.computed_at, now())
  )
  -- Constraint form: the RETURNS TABLE output column `date` is in scope like
  -- a variable, so a bare `date` in an ON CONFLICT target is ambiguous.
  on conflict on constraint health_metrics_pkey do update set
    hrv_sdnn_ms = coalesce(excluded.hrv_sdnn_ms, public.health_metrics.hrv_sdnn_ms),
    resting_hr = coalesce(excluded.resting_hr, public.health_metrics.resting_hr),
    sleep_hours = coalesce(excluded.sleep_hours, public.health_metrics.sleep_hours),
    sleep_deep_hours = coalesce(excluded.sleep_deep_hours, public.health_metrics.sleep_deep_hours),
    sleep_rem_hours = coalesce(excluded.sleep_rem_hours, public.health_metrics.sleep_rem_hours),
    body_mass_kg = coalesce(excluded.body_mass_kg, public.health_metrics.body_mass_kg),
    resp_rate_bpm = coalesce(excluded.resp_rate_bpm, public.health_metrics.resp_rate_bpm),
    -- #109: an omitting-readiness pass (nil) leaves the existing
    -- score/zone/timestamp untouched.
    readiness = coalesce(excluded.readiness, public.health_metrics.readiness),
    zone = coalesce(excluded.zone, public.health_metrics.zone),
    computed_at = coalesce(excluded.computed_at, public.health_metrics.computed_at),
    updated_at = now();

  return query
    select 'written'::text, h.date, h.readiness, h.zone, h.computed_at
    from public.health_metrics h
    where h.user_id = p_user_id and h.date = p_date;
end;
$$;

revoke execute on function public.upsert_health_metrics_with_precedence(
  uuid, date, real, real, real, real, real, real, real, integer, text, timestamptz, text, text
) from public, anon;
grant execute on function public.upsert_health_metrics_with_precedence(
  uuid, date, real, real, real, real, real, real, real, integer, text, timestamptz, text, text
) to authenticated;
