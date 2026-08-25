-- #778: exercise the real post-migration trigger/RPC/account-deletion path.
-- Run the repeatable, local-only repository gate after the local stack has
-- been migrated:
--   npm run test:db:purge
-- The scoped CI workflow resets its disposable local stack before invoking
-- that command. Never replace --local with --linked or --db-url here.
-- Everything is rolled back at the end.

begin;

select plan(21);

-- The local image grants table access to both API roles by default; RLS is
-- therefore asserted below with real role switches. Function execution is
-- narrower: only authenticated may invoke the account-scoped RPCs.
-- A clean --no-seed database has no API-role table grants, so establish only
-- the pre-existing fixture privileges needed to reach those policies. These
-- transaction-scoped grants roll back with the test and never become schema
-- or production privileges.
grant select, update on table public.sessions to authenticated;
grant select, update on table public.tindeq_recordings to authenticated;
grant select on table public.sync_purge_generations to anon;
select is(
  has_table_privilege(
    'authenticated', 'public.sync_purge_generations', 'select'
  ),
  true,
  'authenticated can read the purge-generation endpoint'
);
select is(
  has_function_privilege('anon', 'public.purge_session(uuid)', 'execute'),
  false,
  'anon cannot execute the session purge RPC'
);
select is(
  has_function_privilege('authenticated', 'public.purge_session(uuid)', 'execute'),
  true,
  'authenticated can execute the session purge RPC'
);
select is(
  has_function_privilege('anon', 'public.purge_recording(uuid)', 'execute'),
  false,
  'anon cannot execute the recording purge RPC'
);
select is(
  has_function_privilege('authenticated', 'public.purge_recording(uuid)', 'execute'),
  true,
  'authenticated can execute the recording purge RPC'
);
select is(
  has_function_privilege('anon', 'public.delete_account()', 'execute'),
  false,
  'anon cannot execute account deletion'
);
select is(
  has_function_privilege('authenticated', 'public.delete_account()', 'execute'),
  true,
  'authenticated can execute account deletion'
);

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

-- A second owner lets the authenticated query below prove that RLS filters
-- cross-account rows rather than merely proving that one row exists.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000',
  '77800000-0000-0000-0000-000000000003',
  'authenticated', 'authenticated', '778-rls-other@sendmeter.test',
  extensions.crypt('not-used', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
);
insert into public.sync_purge_generations (user_id, generation)
values ('77800000-0000-0000-0000-000000000003', 9);

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
set local role authenticated;
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
select is(
  (select count(*)::integer from public.sync_purge_generations),
  1,
  'authenticated RLS exposes only the current account generation'
);
select is(
  (select count(*)::integer from public.sync_purge_generations
   where user_id = '77800000-0000-0000-0000-000000000003'),
  0,
  'authenticated RLS hides another account generation'
);

set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select is(
  (select count(*)::integer from public.sync_purge_generations),
  0,
  'anon RLS cannot read any purge-generation row'
);

select * from finish();
rollback;
