-- #521 trigger contract. Run after `supabase db reset` with:
--   npx supabase test db --local supabase/tests/live_mirror_ordering.sql
--
-- The seeded local user is used only to satisfy live_workouts.user_id's
-- auth.users foreign key. Everything is rolled back at the end of the file.
-- The legacy statements intentionally mirror the pre-#521 repository payload:
-- they omit run_id, sequence, event, and terminal from both INSERT and the
-- ON CONFLICT UPDATE set list.
begin;

select plan(9);

delete from public.live_workouts
where user_id = '11111111-1111-1111-1111-111111111111';

-- Legacy INSERT ... ON CONFLICT shape, first landing on an empty slot.
insert into public.live_workouts (
  user_id, workout_id, status, started_at, hr, attempt_count,
  active_kcal, elevation_gain_m, climbing, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'live', '2026-08-09 00:00:00+00', 120, 1,
  5, 2, true, '2026-08-09 00:00:00+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  status = excluded.status,
  started_at = excluded.started_at,
  hr = excluded.hr,
  attempt_count = excluded.attempt_count,
  active_kcal = excluded.active_kcal,
  elevation_gain_m = excluded.elevation_gain_m,
  climbing = excluded.climbing,
  updated_at = excluded.updated_at;

-- A newer legacy heartbeat must update a typed/legacy singleton row even
-- though the omitted metadata columns retain whatever row values already had.
insert into public.live_workouts (
  user_id, workout_id, status, started_at, hr, attempt_count,
  active_kcal, elevation_gain_m, climbing, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'live', '2026-08-09 00:00:00+00', 121, 2,
  6, 3, true, '2026-08-09 00:00:05+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  status = excluded.status,
  started_at = excluded.started_at,
  hr = excluded.hr,
  attempt_count = excluded.attempt_count,
  active_kcal = excluded.active_kcal,
  elevation_gain_m = excluded.elevation_gain_m,
  climbing = excluded.climbing,
  updated_at = excluded.updated_at;

select is(
  (select updated_at from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  '2026-08-09 00:00:05+00'::timestamptz,
  'newer legacy heartbeat updates through the real partial upsert shape'
);

-- An older legacy heartbeat is rejected at the database boundary.
insert into public.live_workouts (
  user_id, workout_id, status, started_at, hr, attempt_count,
  active_kcal, elevation_gain_m, climbing, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'live', '2026-08-09 00:00:00+00', 119, 1,
  4, 1, true, '2026-08-09 00:00:04+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  status = excluded.status,
  started_at = excluded.started_at,
  hr = excluded.hr,
  attempt_count = excluded.attempt_count,
  active_kcal = excluded.active_kcal,
  elevation_gain_m = excluded.elevation_gain_m,
  climbing = excluded.climbing,
  updated_at = excluded.updated_at;

select is(
  (select updated_at from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  '2026-08-09 00:00:05+00'::timestamptz,
  'stale legacy heartbeat is rejected'
);

-- A typed client starts a new run at sequence 5. The full metadata set is
-- named by this upsert, so the typed trigger—not the legacy wall-clock path—
-- owns its ordering.
insert into public.live_workouts (
  user_id, workout_id, run_id, sequence, event, terminal, status,
  started_at, hr, attempt_count, active_kcal, elevation_gain_m,
  climbing, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 5, 'phase', false, 'live',
  '2026-08-09 01:00:00+00', 130, 3, 8, 4, true,
  '2026-08-09 01:00:05+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  run_id = excluded.run_id,
  sequence = excluded.sequence,
  event = excluded.event,
  terminal = excluded.terminal,
  status = excluded.status,
  started_at = excluded.started_at,
  hr = excluded.hr,
  attempt_count = excluded.attempt_count,
  active_kcal = excluded.active_kcal,
  elevation_gain_m = excluded.elevation_gain_m,
  climbing = excluded.climbing,
  updated_at = excluded.updated_at;

-- A stale typed terminal is rejected even though its status is terminal.
insert into public.live_workouts (
  user_id, workout_id, run_id, sequence, event, terminal, status,
  started_at, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 4, 'end', true, 'ended',
  '2026-08-09 01:00:00+00', '2026-08-09 01:00:06+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  run_id = excluded.run_id,
  sequence = excluded.sequence,
  event = excluded.event,
  terminal = excluded.terminal,
  status = excluded.status,
  started_at = excluded.started_at,
  updated_at = excluded.updated_at;

select is(
  (select status || ':' || event || ':' || sequence::text
   from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'live:phase:5',
  'stale typed terminal is rejected by sequence ordering'
);

-- This is the blocking mixed-version case: a real legacy partial End omits
-- all four metadata columns, so conflict update retains sequence 5 instead
-- of presenting sequence 0 to the trigger. It must still land and become
-- terminal.
insert into public.live_workouts (
  user_id, workout_id, status, started_at, hr, attempt_count,
  climbing, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'ended', '2026-08-09 01:00:00+00', null, 0,
  false, '2026-08-09 01:00:07+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  status = excluded.status,
  started_at = excluded.started_at,
  hr = excluded.hr,
  attempt_count = excluded.attempt_count,
  climbing = excluded.climbing,
  updated_at = excluded.updated_at;

select is(
  (select status || ':' || event || ':' || sequence::text || ':' || terminal::text
   from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'ended:end:5:true',
  'legacy partial End after typed sequence 5 lands as terminal'
);

-- A post-End legacy live upsert cannot reopen the row.
insert into public.live_workouts (
  user_id, workout_id, status, started_at, hr, attempt_count,
  climbing, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'live', '2026-08-09 01:00:00+00', 131, 4,
  true, '2026-08-09 01:00:08+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  status = excluded.status,
  started_at = excluded.started_at,
  hr = excluded.hr,
  attempt_count = excluded.attempt_count,
  climbing = excluded.climbing,
  updated_at = excluded.updated_at;

select is(
  (select status || ':' || event || ':' || sequence::text || ':' || terminal::text
   from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'ended:end:5:true',
  'post-End legacy live upsert is rejected'
);

-- A typed live beat after End is rejected even with a higher sequence.
insert into public.live_workouts (
  user_id, workout_id, run_id, sequence, event, terminal, status,
  started_at, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 6, 'telemetry', false, 'live',
  '2026-08-09 01:00:00+00', '2026-08-09 01:00:09+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  run_id = excluded.run_id,
  sequence = excluded.sequence,
  event = excluded.event,
  terminal = excluded.terminal,
  status = excluded.status,
  started_at = excluded.started_at,
  updated_at = excluded.updated_at;

select is(
  (select status || ':' || event || ':' || sequence::text || ':' || terminal::text
   from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'ended:end:5:true',
  'post-End typed live upsert is rejected'
);

-- A newer typed run may replace the terminal singleton row.
insert into public.live_workouts (
  user_id, workout_id, run_id, sequence, event, terminal, status,
  started_at, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'dddddddd-dddd-dddd-dddd-dddddddddddd',
  'dddddddd-dddd-dddd-dddd-dddddddddddd', 1, 'start', false, 'live',
  '2026-08-09 02:00:00+00', '2026-08-09 02:00:01+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  run_id = excluded.run_id,
  sequence = excluded.sequence,
  event = excluded.event,
  terminal = excluded.terminal,
  status = excluded.status,
  started_at = excluded.started_at,
  updated_at = excluded.updated_at;

select is(
  (select run_id from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid,
  'newer typed run replaces a terminal previous run'
);

-- A lower sequence in that new run is stale even with a newer wall clock,
-- and a different run with an older start time is stale regardless of UUID.
insert into public.live_workouts (
  user_id, workout_id, run_id, sequence, event, terminal, status,
  started_at, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'dddddddd-dddd-dddd-dddd-dddddddddddd',
  'dddddddd-dddd-dddd-dddd-dddddddddddd', 0, 'telemetry', false, 'live',
  '2026-08-09 02:00:00+00', '2026-08-09 02:00:02+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  run_id = excluded.run_id,
  sequence = excluded.sequence,
  event = excluded.event,
  terminal = excluded.terminal,
  status = excluded.status,
  started_at = excluded.started_at,
  updated_at = excluded.updated_at;

select is(
  (select sequence from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  1::bigint,
  'typed stale sequence is rejected'
);

insert into public.live_workouts (
  user_id, workout_id, run_id, sequence, event, terminal, status,
  started_at, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
  'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 1, 'start', false, 'live',
  '2026-08-09 01:59:00+00', '2026-08-09 02:00:03+00'
)
on conflict (user_id) do update set
  workout_id = excluded.workout_id,
  run_id = excluded.run_id,
  sequence = excluded.sequence,
  event = excluded.event,
  terminal = excluded.terminal,
  status = excluded.status,
  started_at = excluded.started_at,
  updated_at = excluded.updated_at;

select is(
  (select run_id from public.live_workouts
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid,
  'older different run is rejected'
);

select * from finish();
rollback;
