-- #778: exercise the real post-migration trigger/RPC/account-deletion path.
-- Run after all migrations and seed data are applied:
--   npx supabase db reset
--   npx supabase test db --local supabase/tests/purge_sync_generation.sql
-- Everything is rolled back at the end.

begin;

select plan(11);

-- Account deletion cascades through both trigger-bearing tables. The trigger
-- must not insert a generation row after auth.users has begun disappearing.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000',
  '77800000-0000-0000-0000-000000000001',
  'authenticated', 'authenticated', '778-account-delete@sendmeter.test',
  extensions.crypt('not-used', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
);

insert into public.sessions (
  id, user_id, date, type, type_label, duration_min, rpe, phase
) values (
  '77800000-0000-0000-0000-000000000011',
  '77800000-0000-0000-0000-000000000001',
  current_date, 'board', 'Board Climbing', 60, 7, 'strength'
);

insert into public.tindeq_recordings (
  id, user_id, duration_ms, peak_kg, avg_kg, sample_count, note, samples,
  tag, side, source
) values (
  '77800000-0000-0000-0000-000000000012',
  '77800000-0000-0000-0000-000000000001',
  7000, 32, 28, 2, '', '[[0,28],[7000,32]]'::jsonb,
  'FDP', 'left', 'dynamometer'
);

select set_config(
  'request.jwt.claim.sub',
  '77800000-0000-0000-0000-000000000001',
  true
);

select lives_ok(
  $$select public.delete_account()$$,
  'delete_account succeeds when the account owns both hard-delete trigger tables'
);
select is(
  (select count(*)::integer from auth.users
   where id = '77800000-0000-0000-0000-000000000001'),
  0,
  'account parent is deleted'
);
select is(
  (select count(*)::integer from public.sessions
   where user_id = '77800000-0000-0000-0000-000000000001'),
  0,
  'session cascade completes without the generation FK failing'
);
select is(
  (select count(*)::integer from public.tindeq_recordings
   where user_id = '77800000-0000-0000-0000-000000000001'),
  0,
  'recording cascade completes without the generation FK failing'
);
select is(
  (select count(*)::integer from public.sync_purge_generations
   where user_id = '77800000-0000-0000-0000-000000000001'),
  0,
  'account deletion leaves no orphaned purge-generation row'
);

-- The normal purge path still increments atomically and retries are safe.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000',
  '77800000-0000-0000-0000-000000000002',
  'authenticated', 'authenticated', '778-account-purge@sendmeter.test',
  extensions.crypt('not-used', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
);

insert into public.sessions (
  id, user_id, date, type, type_label, duration_min, rpe, phase
) values (
  '77800000-0000-0000-0000-000000000021',
  '77800000-0000-0000-0000-000000000002',
  current_date, 'board', 'Board Climbing', 60, 7, 'strength'
);

insert into public.tindeq_recordings (
  id, user_id, duration_ms, peak_kg, avg_kg, sample_count, note, samples,
  tag, side, source
) values (
  '77800000-0000-0000-0000-000000000022',
  '77800000-0000-0000-0000-000000000002',
  7000, 32, 28, 2, '', '[[0,28],[7000,32]]'::jsonb,
  'FDP', 'left', 'dynamometer'
);

select set_config(
  'request.jwt.claim.sub',
  '77800000-0000-0000-0000-000000000002',
  true
);
update public.sessions set deleted_at = now()
where id = '77800000-0000-0000-0000-000000000021';
update public.tindeq_recordings set deleted_at = now()
where id = '77800000-0000-0000-0000-000000000022';

select is(
  public.purge_session('77800000-0000-0000-0000-000000000021'),
  true,
  'first session purge reports that it deleted a Trash row'
);
select is(
  (select generation from public.sync_purge_generations
   where user_id = '77800000-0000-0000-0000-000000000002'),
  1::bigint,
  'session purge increments the per-account generation'
);
select is(
  public.purge_recording('77800000-0000-0000-0000-000000000022'),
  true,
  'first recording purge reports that it deleted a Trash row'
);
select is(
  (select generation from public.sync_purge_generations
   where user_id = '77800000-0000-0000-0000-000000000002'),
  2::bigint,
  'recording purge shares the same generation counter'
);
select is(
  public.purge_session('77800000-0000-0000-0000-000000000021'),
  false,
  'retrying an already completed purge is an intentional false no-op'
);
select is(
  public.purge_recording('77800000-0000-0000-0000-000000000022'),
  false,
  'retrying an already completed recording purge is an intentional false no-op'
);

select * from finish();
rollback;
