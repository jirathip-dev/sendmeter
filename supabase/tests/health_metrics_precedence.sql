-- #802 AC4: server-side precedence RPC decide matrix. Run after
-- `supabase db reset` with:
--   npx supabase test db --local supabase/tests/health_metrics_precedence.sql
--
-- The seeded local user satisfies the auth.users FK; the whole file rolls
-- back at the end. Every RPC invocation is wrapped in a pgTAP assertion —
-- a bare `select *` row would break the TAP stream.
begin;

select plan(22);

-- The scoped CI workflow resets with --no-seed, so create this test's own
-- auth user (mirrors purge_sync_generation.sql) instead of relying on seed.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000',
  '80200000-0000-0000-0000-000000000001',
  'authenticated', 'authenticated', '802-precedence@sendmeter.test',
  extensions.crypt('not-used', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
);

-- Fixture dates far from the seed window; all instants are explicit, so no
-- session-timezone dependency exists.
delete from public.health_metrics
where user_id = '80200000-0000-0000-0000-000000000001'
  and date between '2026-01-01' and '2026-01-31';

-- 1. Empty candidate: discarded, no row created.
select is(r.decision, 'discarded',
  '1: empty candidate is discarded')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-05',
  null, null, null, null, null, null, null,
  null, null,
  '2026-01-05 06:00:00+00',
  'watch', 'Asia/Bangkok') r;
select is(count(*)::integer, 0,
  '1: no row persisted for an empty candidate')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000001'
  and h.date = '2026-01-05';

-- 2. Watch writes when no row exists.
select is(r.decision, 'written',
  '2: watch writes a missing date')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-05',
  55::real, 60::real, 7::real, 1.5::real, 1::real, 70::real, 14::real,
  82, 'maintain',
  '2026-01-05 06:00:00+00',
  'watch', 'Asia/Bangkok') r;
select is(h.readiness, 82,
  '2: watch-scored row persisted')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000001'
  and h.date = '2026-01-05';

-- 3. Phone wins over a fresh non-empty row (phone writer, same local day).
select is(r.decision, 'written',
  '3: phone wins over fresh row')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-05',
  58::real, 61::real, 7.2::real, 1.6::real, 1.1::real, 70.5::real, 14.1::real,
  76, 'maintain',
  '2026-01-05 09:00:00+00',
  'phone', 'Asia/Bangkok') r;
select is(h.readiness, 76,
  '3: phone score replaced the row')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000001'
  and h.date = '2026-01-05';

-- 4. Watch retains a fresh non-empty row (no flap).
select is(r.decision, 'retained',
  '4: watch retains fresh non-empty row')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-05',
  51::real, 62::real, 8::real, 2::real, 1.2::real, 68::real, 13.8::real,
  90, 'push',
  '2026-01-05 06:00:00+00',
  'watch', 'Asia/Bangkok') r;
select is(h.readiness, 76,
  '4: retained row keeps its score')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000001'
  and h.date = '2026-01-05';

-- 5. Watch writes over a STALE row (row computed on yesterday's local day).
select is(r.decision, 'written',
  '5: stale phone row seeded')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-06',
  55::real, 60::real, 7::real, 1.5::real, 1::real, 70::real, 14::real,
  80, 'maintain',
  '2026-01-05 23:50:00+08',
  'phone', 'Asia/Bangkok') r;
select is(r.decision, 'written',
  '5: watch rewrites a stale phone row')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-06',
  50::real, 59::real, 6.5::real, 1.4::real, 0.9::real, 69::real, 14.2::real,
  84, 'maintain',
  '2026-01-06 05:00:00+08',
  'watch', 'Asia/Bangkok') r;
select is(h.readiness, 84,
  '5: stale phone row replaced by watch')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000001'
  and h.date = '2026-01-06';

-- 6. Freshness is zone-explicit: the SAME instant is same-day in Bangkok
--    and previous-day in UTC.
select is(r.decision, 'written',
  '6: fixture row seeded (00:30 Bangkok)')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-07',
  55::real, 60::real, 7::real, 1.5::real, 1::real, 70::real, 14::real,
  81, 'maintain',
  '2026-01-07 00:30:00+07',
  'watch', 'Asia/Bangkok') r;
select is(r.decision, 'retained',
  '6a: Bangkok sees same-day — retained')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-07',
  52::real, 63::real, 8.5::real, 2.1::real, 1.3::real, 71::real, 13.6::real,
  93, 'push',
  '2026-01-07 07:00:00+01',
  'watch', 'Asia/Bangkok') r;
select is(r.decision, 'written',
  '6b: UTC sees previous-day — written')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-07',
  52::real, 63::real, 8.5::real, 2.1::real, 1.3::real, 71::real, 13.6::real,
  93, 'push',
  '2026-01-07 07:00:00+01',
  'watch', 'UTC') r;

-- 7. Phone empty candidate: discarded, existing row untouched.
select is(r.decision, 'discarded',
  '7: phone empty candidate discarded')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-07',
  null, null, null, null, null, null, null,
  null, null,
  '2026-01-07 08:00:00+01',
  'phone', 'UTC') r;
select is(h.readiness, 93,
  '7: discarded write left the row untouched')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000001'
  and h.date = '2026-01-07';

-- 8. #109 keep-score: an omitting-readiness candidate (nil readiness/zone/
--    computed_at) merges biometrics but keeps the existing score.
select is(r.decision, 'written',
  '8: omitting-readiness candidate written')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-07',
  58::real, 60::real, 7.8::real, 1.7::real, 1.1::real, 70::real, 14::real,
  null, null,
  null,
  'watch', 'UTC') r;
select is(h.readiness, 93,
  '8: kept score survives the merge')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000001'
  and h.date = '2026-01-07';
select is(h.hrv_sdnn_ms, 58::real,
  '8: biometrics replaced')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000001'
  and h.date = '2026-01-07';

-- 9. Idempotent: repeated writes never create duplicates.
select is(r.decision, 'written',
  '9: first repeat written')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-08',
  50::real, 59::real, 6.5::real, 1.4::real, 0.9::real, 69::real, 14.2::real,
  84, 'maintain',
  '2026-01-08 05:00:00+07',
  'watch', 'Asia/Bangkok') r;
select is(r.decision, 'retained',
  '9: second repeat retained (fresh own row)')
from public.upsert_health_metrics_with_precedence(
  '80200000-0000-0000-0000-000000000001',
  '2026-01-08',
  51::real, 58::real, 6.8::real, 1.5::real, 1::real, 69.5::real, 14.1::real,
  85, 'maintain',
  '2026-01-08 06:00:00+07',
  'watch', 'Asia/Bangkok') r;
select is(count(*)::integer, 1,
  '9: one row per user per date after repeats')
from public.health_metrics h
where h.user_id = '80200000-0000-0000-0000-000000000001'
  and h.date = '2026-01-08';

rollback;
