-- #521 trigger contract. Run after `supabase db reset` with:
--   npx supabase test db --local supabase/tests/live_mirror_ordering.sql
--
-- The seeded local user is used only to satisfy live_workouts.user_id's
-- auth.users foreign key. Everything is rolled back at the end of the file.
begin;

select plan(6);

delete from public.live_workouts
where user_id = '11111111-1111-1111-1111-111111111111';

-- A legacy watch has no run metadata and therefore stays at sequence 0.
insert into public.live_workouts (
  user_id, workout_id, status, started_at, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'live',
  '2026-08-09 00:00:00+00',
  '2026-08-09 00:00:00+00'
);

-- Legacy 0/0 rows use updated_at ordering, so a newer heartbeat replaces the
-- first one instead of being discarded by 0 <= 0.
update public.live_workouts
set status = 'live',
    updated_at = '2026-08-09 00:00:05+00',
    sequence = 0,
    event = 'telemetry',
    terminal = false
where user_id = '11111111-1111-1111-1111-111111111111';

select is(
  (select updated_at from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  '2026-08-09 00:00:05+00'::timestamptz,
  'newer legacy heartbeat updates the 0/0 row'
);

-- An older legacy heartbeat is rejected even if it arrives after the newer
-- one at the database boundary.
update public.live_workouts
set status = 'live',
    updated_at = '2026-08-09 00:00:04+00',
    sequence = 0,
    event = 'telemetry',
    terminal = false
where user_id = '11111111-1111-1111-1111-111111111111';

select is(
  (select updated_at from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  '2026-08-09 00:00:05+00'::timestamptz,
  'stale legacy heartbeat is rejected'
);

-- Legacy End is terminal even though its sequence is still zero; terminal
-- wins before the legacy wall-clock comparison.
update public.live_workouts
set status = 'ended',
    updated_at = '2026-08-09 00:00:06+00',
    sequence = 0,
    event = 'telemetry',
    terminal = false
where user_id = '11111111-1111-1111-1111-111111111111';

select is(
  (select status || ':' || event || ':' || terminal::text
   from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'ended:end:true',
  'legacy End lands as a terminal end row'
);

-- A late legacy live packet cannot reopen a terminal row.
update public.live_workouts
set status = 'live',
    updated_at = '2026-08-09 00:00:07+00',
    sequence = 0,
    event = 'telemetry',
    terminal = false
where user_id = '11111111-1111-1111-1111-111111111111';

select is(
  (select status || ':' || event || ':' || terminal::text
   from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'ended:end:true',
  'post-End legacy live packet is rejected'
);

-- A new-client run carries an explicit sequence. A lower sequence is stale
-- even when its updated_at is newer.
update public.live_workouts
set workout_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    run_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    status = 'live',
    started_at = '2026-08-09 01:00:00+00',
    updated_at = '2026-08-09 01:00:05+00',
    sequence = 5,
    event = 'phase',
    terminal = false
where user_id = '11111111-1111-1111-1111-111111111111';

update public.live_workouts
set status = 'live',
    updated_at = '2026-08-09 01:00:06+00',
    sequence = 4,
    event = 'telemetry',
    terminal = false
where user_id = '11111111-1111-1111-1111-111111111111';

select is(
  (select sequence from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  5::bigint,
  'new-client stale sequence is rejected'
);

-- A different run with an older start time is also stale; UUIDs are opaque,
-- so started_at is the mixed-version ordering signal.
update public.live_workouts
set workout_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc',
    run_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc',
    status = 'live',
    started_at = '2026-08-09 00:59:00+00',
    updated_at = '2026-08-09 01:00:07+00',
    sequence = 1,
    event = 'start',
    terminal = false
where user_id = '11111111-1111-1111-1111-111111111111';

select is(
  (select run_id from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
  'older different run is rejected'
);

select * from finish();
rollback;
