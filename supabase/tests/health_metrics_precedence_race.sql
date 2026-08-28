-- #802 AC4: deterministic two-session concurrency regression for the
-- precedence RPC (runner: scripts/test-health-precedence-race.sh).
--
-- Reviewer's race: the watch's RPC starts while the (user_id, date) row is
-- MISSING; `SELECT ... FOR UPDATE` locks nothing for an absent key, so a
-- phone writer landing midway is then clobbered by the watch's insert
-- without re-evaluating precedence.
--
-- The script's holder session owns the per-date ADVISORY LOCK while this
-- pgTAP session's first RPC is in flight: the FIXED RPC must block on it
-- (statement_timeout → SQLSTATE 57014 — the red/green discriminator; the
-- unfixed RPC takes no lock and completes). The script's second session
-- already committed a fresh PHONE row, so the delayed watch pass must
-- RETAIN it and never overwrite (it blocks on the same lock until the
-- holder releases it, making that ordering structural, not timed).
begin;

select plan(4);

-- 1. RPC#1: the watch pass in flight while the holder owns the advisory
--    lock → the FIXED RPC blocks and times out (query_canceled, SQLSTATE
--    57014). The unfixed RPC takes no lock and completes — this assertion
--    fails, discriminating the fix. (pgTAP's throws_ok re-raises codes
--    outside its supported set and a statement timeout meters per
--    STATEMENT, so the probe is a plpgsql wrapper and the 900ms budget is
--    set in the PREVIOUS statement.)
create or replace function public.__probe_health_precedence_blocks() returns boolean
language plpgsql as $$
begin
  begin
    perform * from public.upsert_health_metrics_with_precedence(
      '80200000-0000-0000-0000-000000000003',
      '2026-01-21',
      55::real, 60::real, 7::real, 1.5::real, 1::real, 70::real, 14::real,
      84, 'maintain',
      '2026-01-21 05:00:00+07',
      'watch', 'Asia/Bangkok'
    );
    return false; -- completed immediately: the lock did NOT serialize
  exception
    when query_canceled then
      return true; -- blocked on the advisory lock: absent-key race closed
  end;
end;
$$;
select set_config('statement_timeout', '900', true);
select is(public.__probe_health_precedence_blocks(), true,
  'watch RPC blocks on the per-date advisory lock (absent-key race)');
select set_config('statement_timeout', '0', true);
drop function public.__probe_health_precedence_blocks();

-- RPC#2 blocks on the same lock until the holder releases it, so it is
-- structurally ordered AFTER the phone row's commit — no sleep needed for
-- correctness; this only bounds the test length.
select pg_sleep(4);

-- 2. RPC#2: the delayed watch pass — the fresh phone row now owns the
--    date, so the watch must RETAIN.
select is(r.decision, 'retained',
  'delayed watch pass retains the fresh phone row (no overwrite)')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000003',
  '2026-01-21',
  55::real, 60::real, 7::real, 1.5::real, 1::real, 70::real, 14::real,
  90, 'push',
  '2026-01-21 09:00:00+07',
  'watch', 'Asia/Bangkok') r;

-- 3. The row still carries the phone writer's score.
select is(h.readiness, 70,
  'phone score survives the delayed watch pass')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000003'
  and h.date = '2026-01-21';

-- 4. ... and the phone writer's biometrics.
select is(h.hrv_sdnn_ms, 70::real,
  'phone biometrics survive the delayed watch pass')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000003'
  and h.date = '2026-01-21';

rollback;
