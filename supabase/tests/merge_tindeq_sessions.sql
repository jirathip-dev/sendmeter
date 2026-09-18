-- #942: `merge_tindeq_sessions` — the atomic same-day Tindeq merge.
-- Run after `supabase db reset` with:
--   npx supabase test db --local supabase/tests/merge_tindeq_sessions.sql
--
-- The scoped CI workflow resets with --no-seed, so this test creates its own
-- auth users (mirrors purge_sync_generation.sql). Everything rolls back at
-- the end.
--
-- RED/GREEN discipline: the cross-account proofs run under a REAL role switch
-- (`set local role authenticated` + a `request.jwt.claim.sub` the function's
-- `auth.uid()` reads), because `security invoker` + RLS is the mechanism that
-- must reject a foreign session. A superuser run would see every row and
-- prove nothing. The atomicity case forces a mid-function failure (RPE 11
-- trips `sessions_rpe_check`) and asserts that the re-point and the deletes
-- rolled back with it.

begin;

select plan(37);

-- A clean --no-seed database has no API-role table grants, so establish only
-- the pre-existing fixture privileges the policies/statements below need.
-- Transaction-scoped; rolls back with the test.
grant select, update on table public.sessions to authenticated;
grant select, update on table public.tindeq_recordings to authenticated;

-- Caller (A) and a second owner (B) whose rows must be untouchable.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values
(
  '00000000-0000-0000-0000-000000000000',
  '94200000-0000-0000-0000-000000000001',
  'authenticated', 'authenticated', '942-merge@sendmeter.test',
  extensions.crypt('not-used', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
),
(
  '00000000-0000-0000-0000-000000000000',
  '94200000-0000-0000-0000-000000000002',
  'authenticated', 'authenticated', '942-merge-other@sendmeter.test',
  extensions.crypt('not-used', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
);

-- A's same-day Tindeq sessions, one group each: A1 (survivor candidate,
-- 10:00), A2 (10:30), A3 (11:00). A4 is the same type on the NEXT day, A5 is
-- a non-Tindeq session on the same day, A6/A7 are an already-trashed pair.
insert into public.sessions (
  id, user_id, date, type, type_label, duration_min, rpe, rpe_confirmed,
  note, phase, group_id, deleted_at
) values
(
  '94200000-0000-0000-0000-000000000011', '94200000-0000-0000-0000-000000000001',
  '2026-01-20', 'tindeq', 'Tindeq', 30, 6, true,
  '1 recording · FDP', 'capacity', '94200000-0000-0000-0000-0000000000a1', null
),
(
  '94200000-0000-0000-0000-000000000012', '94200000-0000-0000-0000-000000000001',
  '2026-01-20', 'tindeq', 'Tindeq', 20, 5.5, false,
  '1 recording · FDP', 'capacity', '94200000-0000-0000-0000-0000000000a2', null
),
(
  '94200000-0000-0000-0000-000000000013', '94200000-0000-0000-0000-000000000001',
  '2026-01-20', 'tindeq', 'Tindeq', 15, 7, false,
  '1 recording · MWF', 'capacity', '94200000-0000-0000-0000-0000000000a3', null
),
(
  '94200000-0000-0000-0000-000000000014', '94200000-0000-0000-0000-000000000001',
  '2026-01-21', 'tindeq', 'Tindeq', 30, 6, false,
  '1 recording · FDP', 'capacity', '94200000-0000-0000-0000-0000000000a4', null
),
(
  '94200000-0000-0000-0000-000000000015', '94200000-0000-0000-0000-000000000001',
  '2026-01-20', 'fingerboard', 'Fingerboard', 45, 6, true,
  '', 'capacity', '94200000-0000-0000-0000-0000000000a5', null
),
(
  '94200000-0000-0000-0000-000000000016', '94200000-0000-0000-0000-000000000001',
  '2026-01-20', 'tindeq', 'Tindeq', 12, 5, false,
  '1 recording · FDP', 'capacity', null, now()
),
(
  '94200000-0000-0000-0000-000000000017', '94200000-0000-0000-0000-000000000001',
  '2026-01-20', 'tindeq', 'Tindeq', 12, 5, false,
  '1 recording · FDP', 'capacity', null, now()
);

-- A's recordings. r1b is a TRASHED recording in A1's group: it is not part of
-- the merged effort (count/duration/note ignore it) but must follow the group
-- re-point, or a later restore would strand it in a group no session owns.
insert into public.tindeq_recordings (
  id, user_id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note,
  samples, tag, side, source, group_id, deleted_at
) values
(
  '94200000-0000-0000-0000-0000000000c1', '94200000-0000-0000-0000-000000000001',
  '2026-01-20 10:00:00+00', 60000, 32, 28, 2, '',
  '[[0,28],[60000,32]]'::jsonb, 'FDP', 'left', 'dynamometer',
  '94200000-0000-0000-0000-0000000000a1', null
),
(
  '94200000-0000-0000-0000-0000000000c2', '94200000-0000-0000-0000-000000000001',
  '2026-01-20 09:30:00+00', 60000, 30, 26, 2, '',
  '[[0,26],[60000,30]]'::jsonb, 'FDP', 'left', 'dynamometer',
  '94200000-0000-0000-0000-0000000000a1', now()
),
(
  '94200000-0000-0000-0000-0000000000c3', '94200000-0000-0000-0000-000000000001',
  '2026-01-20 10:30:00+00', 60000, 34, 30, 2, '',
  '[[0,30],[60000,34]]'::jsonb, 'FDP', 'left', 'dynamometer',
  '94200000-0000-0000-0000-0000000000a2', null
),
(
  '94200000-0000-0000-0000-0000000000c4', '94200000-0000-0000-0000-000000000001',
  '2026-01-20 11:00:00+00', 60000, 36, 31, 2, '',
  '[[0,31],[60000,36]]'::jsonb, 'MWF', 'left', 'dynamometer',
  '94200000-0000-0000-0000-0000000000a3', null
),
(
  '94200000-0000-0000-0000-0000000000c5', '94200000-0000-0000-0000-000000000001',
  '2026-01-20 09:00:00+00', 60000, 29, 25, 2, '',
  '[[0,25],[60000,29]]'::jsonb, 'FDP', 'left', 'dynamometer',
  '94200000-0000-0000-0000-0000000000a5', null
);

-- B owns two same-day Tindeq sessions; nothing A does may touch them.
insert into public.sessions (
  id, user_id, date, type, type_label, duration_min, rpe, rpe_confirmed,
  note, phase, group_id
) values
(
  '94200000-0000-0000-0000-000000000021', '94200000-0000-0000-0000-000000000002',
  '2026-01-20', 'tindeq', 'Tindeq', 25, 6, false,
  '1 recording · FDP', 'capacity', '94200000-0000-0000-0000-0000000000b1'
),
(
  '94200000-0000-0000-0000-000000000022', '94200000-0000-0000-0000-000000000002',
  '2026-01-20', 'tindeq', 'Tindeq', 25, 6, false,
  '1 recording · FDP', 'capacity', '94200000-0000-0000-0000-0000000000b2'
);

insert into public.tindeq_recordings (
  id, user_id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note,
  samples, tag, side, source, group_id
) values (
  '94200000-0000-0000-0000-0000000000d1', '94200000-0000-0000-0000-000000000002',
  '2026-01-20 11:00:00+00', 60000, 33, 29, 2, '',
  '[[0,29],[60000,33]]'::jsonb, 'FDP', 'left', 'dynamometer',
  '94200000-0000-0000-0000-0000000000b1'
);

-- Function execution is narrower than table access: only authenticated may
-- invoke the merge RPC (the app always runs as a signed-in caller).
select is(
  has_function_privilege(
    'anon',
    'public.merge_tindeq_sessions(uuid[],uuid,numeric,boolean)',
    'execute'
  ),
  false,
  'anon cannot execute the merge RPC'
);
select is(
  has_function_privilege(
    'authenticated',
    'public.merge_tindeq_sessions(uuid[],uuid,numeric,boolean)',
    'execute'
  ),
  true,
  'authenticated can execute the merge RPC'
);

-- ===========================================================================
-- Caller A: the RED half. Every rejection below must leave BOTH accounts
-- byte-identical — a rejected merge may not have moved anything.
-- ===========================================================================
select set_config(
  'request.jwt.claim.sub',
  '94200000-0000-0000-0000-000000000001',
  true
);
set local role authenticated;

-- 1. Cross-account: B's sessions are invisible under RLS, so the id set
--    cannot be satisfied and the call fails closed.
select throws_ok(
  $q$
    select * from public.merge_tindeq_sessions(
      array[
        '94200000-0000-0000-0000-000000000021'::uuid,
        '94200000-0000-0000-0000-000000000022'::uuid
      ],
      '94200000-0000-0000-0000-000000000021'::uuid,
      6,
      false
    )
  $q$,
  'P0001',
  'merge rejected: session not found',
  'RED: a foreign account''s sessions cannot be merged'
);

-- 2. A mixed list (one own session + one foreign session) must fail as a
--    whole, not merge the own half.
select throws_ok(
  $q$
    select * from public.merge_tindeq_sessions(
      array[
        '94200000-0000-0000-0000-000000000011'::uuid,
        '94200000-0000-0000-0000-000000000021'::uuid
      ],
      '94200000-0000-0000-0000-000000000011'::uuid,
      6,
      false
    )
  $q$,
  'P0001',
  'merge rejected: session not found',
  'RED: a foreign id mixed into the selection rejects the whole merge'
);

-- B's rows are invisible to A under RLS, so the "untouched" proof has to be
-- read as B. (The count below is also the RLS-filtered view: two rows.)
select set_config(
  'request.jwt.claim.sub',
  '94200000-0000-0000-0000-000000000002',
  true
);
select is(
  (
    select count(*)::integer
    from public.sessions
    where user_id = '94200000-0000-0000-0000-000000000002'
      and deleted_at is null
  ),
  2,
  'RED: the foreign account still has both its sessions'
);
select is(
  (
    select group_id
    from public.tindeq_recordings
    where id = '94200000-0000-0000-0000-0000000000d1'
  ),
  '94200000-0000-0000-0000-0000000000b1'::uuid,
  'RED: the foreign recording was not re-pointed'
);
select set_config(
  'request.jwt.claim.sub',
  '94200000-0000-0000-0000-000000000001',
  true
);
select is(
  (
    select count(*)::integer
    from public.sessions
    where user_id = '94200000-0000-0000-0000-000000000001'
      and deleted_at is null
  ),
  5,
  'RED: the caller''s own sessions are untouched by the rejected calls'
);
select is(
  (
    select group_id
    from public.tindeq_recordings
    where id = '94200000-0000-0000-0000-0000000000c5'
  ),
  '94200000-0000-0000-0000-0000000000a5'::uuid,
  'RED: the non-Tindeq session''s recording kept its group'
);

-- 3. Cross-day: A1 (2026-01-20) + A4 (2026-01-21).
select throws_ok(
  $q$
    select * from public.merge_tindeq_sessions(
      array[
        '94200000-0000-0000-0000-000000000011'::uuid,
        '94200000-0000-0000-0000-000000000014'::uuid
      ],
      '94200000-0000-0000-0000-000000000011'::uuid,
      6,
      false
    )
  $q$,
  'P0001',
  'merge rejected: sessions must share one local day',
  'RED: sessions from different local days cannot be merged'
);

-- 4. Non-Tindeq: A1 (tindeq) + A5 (fingerboard).
select throws_ok(
  $q$
    select * from public.merge_tindeq_sessions(
      array[
        '94200000-0000-0000-0000-000000000011'::uuid,
        '94200000-0000-0000-0000-000000000015'::uuid
      ],
      '94200000-0000-0000-0000-000000000011'::uuid,
      6,
      false
    )
  $q$,
  'P0001',
  'merge rejected: only tindeq sessions can be merged',
  'RED: a non-Tindeq session cannot be merged'
);

-- 5. Survivor outside the selection.
select throws_ok(
  $q$
    select * from public.merge_tindeq_sessions(
      array[
        '94200000-0000-0000-0000-000000000011'::uuid,
        '94200000-0000-0000-0000-000000000012'::uuid
      ],
      '94200000-0000-0000-0000-000000000013'::uuid,
      6,
      false
    )
  $q$,
  'P0001',
  'merge rejected: survivor must be one of the merged sessions',
  'RED: the survivor must be one of the selected sessions'
);

-- 6. Degenerate selections: one distinct session (a duplicate id collapses to
--    one), and a pair that is already fully trashed.
select throws_ok(
  $q$
    select * from public.merge_tindeq_sessions(
      array[
        '94200000-0000-0000-0000-000000000011'::uuid,
        '94200000-0000-0000-0000-000000000011'::uuid
      ],
      '94200000-0000-0000-0000-000000000011'::uuid,
      6,
      false
    )
  $q$,
  'P0001',
  'merge rejected: at least two sessions are required',
  'RED: a single distinct session cannot be merged'
);
select throws_ok(
  $q$
    select * from public.merge_tindeq_sessions(
      array[
        '94200000-0000-0000-0000-000000000016'::uuid,
        '94200000-0000-0000-0000-000000000017'::uuid
      ],
      '94200000-0000-0000-0000-000000000016'::uuid,
      6,
      false
    )
  $q$,
  'P0001',
  'merge rejected: sessions already deleted',
  'RED: an all-trashed selection cannot be merged'
);

-- ===========================================================================
-- ATOMICITY: RPE 11 trips `sessions_rpe_check` inside the function. Every
-- earlier statement (the group re-point, the survivor update) must roll back,
-- and the sessions must still be live — the no-orphaned-recordings guarantee.
-- ===========================================================================
select throws_ok(
  $q$
    select * from public.merge_tindeq_sessions(
      array[
        '94200000-0000-0000-0000-000000000011'::uuid,
        '94200000-0000-0000-0000-000000000012'::uuid,
        '94200000-0000-0000-0000-000000000013'::uuid
      ],
      '94200000-0000-0000-0000-000000000011'::uuid,
      11,
      false
    )
  $q$,
  '23514',
  null,
  'ATOMIC: a mid-function failure surfaces as a constraint violation'
);
select is(
  (
    select count(*)::integer
    from public.sessions
    where id in (
      '94200000-0000-0000-0000-000000000011',
      '94200000-0000-0000-0000-000000000012',
      '94200000-0000-0000-0000-000000000013'
    )
      and deleted_at is null
  ),
  3,
  'ATOMIC: the failed merge left all three sessions live'
);
select is(
  (
    select count(*)::integer
    from public.tindeq_recordings
    where id in (
      '94200000-0000-0000-0000-0000000000c1',
      '94200000-0000-0000-0000-0000000000c3',
      '94200000-0000-0000-0000-0000000000c4'
    )
      and group_id = '94200000-0000-0000-0000-0000000000a1'
  ),
  1,
  'ATOMIC: the failed merge re-pointed no recording'
);
select is(
  (
    select rpe
    from public.sessions
    where id = '94200000-0000-0000-0000-000000000011'
  ),
  6::numeric,
  'ATOMIC: the survivor row kept its original RPE'
);

-- ===========================================================================
-- GREEN: merge A1 + A2 + A3 onto A1. One call, four returned-column
-- assertions.
-- ===========================================================================
select is(r.group_id, '94200000-0000-0000-0000-0000000000a1'::uuid,
          'GREEN: the survivor keeps its own group id'),
       is(r.duration_min, 61,
          'GREEN: duration is the full span (10:00:00 → 11:01:00)'),
       is(r.recording_count, 3,
          'GREEN: the three live recordings are counted'),
       is(r.note, '3 recordings · FDP, MWF',
          'GREEN: the note lists every recording''s tag')
from public.merge_tindeq_sessions(
  array[
    '94200000-0000-0000-0000-000000000011'::uuid,
    '94200000-0000-0000-0000-000000000012'::uuid,
    '94200000-0000-0000-0000-000000000013'::uuid
  ],
  '94200000-0000-0000-0000-000000000011'::uuid,
  7.5,
  false
) r;

select is(
  (
    select count(*)::integer
    from public.sessions
    where user_id = '94200000-0000-0000-0000-000000000001'
      and deleted_at is null
  ),
  3,
  'GREEN: A1 survived, A2/A3 are out of the live list (A4/A5 untouched)'
);
select is(
  (
    select count(*)::integer
    from public.sessions
    where id in (
      '94200000-0000-0000-0000-000000000012',
      '94200000-0000-0000-0000-000000000013'
    )
  ),
  2,
  'GREEN: the merged-away sessions are soft-deleted, not purged'
);
select is(
  (
    select count(*)::integer
    from public.tindeq_recordings
    where id in (
      '94200000-0000-0000-0000-0000000000c1',
      '94200000-0000-0000-0000-0000000000c3',
      '94200000-0000-0000-0000-0000000000c4'
    )
      and group_id = '94200000-0000-0000-0000-0000000000a1'
  ),
  3,
  'GREEN: every recording now belongs to the surviving group'
);
select is(
  (
    select count(*)::integer
    from public.tindeq_recordings
    where group_id in (
      '94200000-0000-0000-0000-0000000000a2',
      '94200000-0000-0000-0000-0000000000a3'
    )
  ),
  0,
  'GREEN: no recording is left behind in a merged-away group'
);
select is(
  (
    select group_id
    from public.tindeq_recordings
    where id = '94200000-0000-0000-0000-0000000000c2'
  ),
  '94200000-0000-0000-0000-0000000000a1'::uuid,
  'GREEN: a trashed recording follows the group so a restore is not orphaned'
);
select is(
  (
    select rpe
    from public.sessions
    where id = '94200000-0000-0000-0000-000000000011'
  ),
  7.5::numeric,
  'GREEN: the planned RPE was written to the survivor'
);
select is(
  (
    select rpe_confirmed
    from public.sessions
    where id = '94200000-0000-0000-0000-000000000011'
  ),
  false,
  'GREEN: the unconfirmed prediction stays unconfirmed'
);
select is(
  (
    select date
    from public.sessions
    where id = '94200000-0000-0000-0000-000000000011'
  ),
  '2026-01-20'::date,
  'GREEN: the survivor keeps the shared local day'
);
select is(
  (
    select load
    from public.sessions
    where id = '94200000-0000-0000-0000-000000000011'
  ),
  458,
  'GREEN: the generated load follows the merged duration and RPE'
);

-- ===========================================================================
-- IDEMPOTENT RETRY: the offline queue can replay the exact payload after a
-- lost response. The second call must report the applied merge, not raise.
-- ===========================================================================
select is(r.group_id, '94200000-0000-0000-0000-0000000000a1'::uuid,
          'RETRY: the replayed merge reports the same surviving group'),
       is(r.recording_count, 3,
          'RETRY: the replayed merge reports the same recording count')
from public.merge_tindeq_sessions(
  array[
    '94200000-0000-0000-0000-000000000011'::uuid,
    '94200000-0000-0000-0000-000000000012'::uuid,
    '94200000-0000-0000-0000-000000000013'::uuid
  ],
  '94200000-0000-0000-0000-000000000011'::uuid,
  7.5,
  false
) r;
select is(
  (
    select count(*)::integer
    from public.sessions
    where user_id = '94200000-0000-0000-0000-000000000001'
      and deleted_at is null
  ),
  3,
  'RETRY: the replay deleted nothing else'
);

-- ===========================================================================
-- The other side of RLS: as B, A's rows (and the merged result) are invisible,
-- and a foreign merge is rejected from that direction too.
-- ===========================================================================
select set_config(
  'request.jwt.claim.sub',
  '94200000-0000-0000-0000-000000000002',
  true
);
select is(
  (select count(*)::integer from public.sessions),
  2,
  'RLS: B sees only its own two sessions'
);
select is(
  (
    select count(*)::integer
    from public.sessions
    where id = '94200000-0000-0000-0000-000000000011'
  ),
  0,
  'RLS: the merged survivor is invisible to B'
);
select throws_ok(
  $q$
    select * from public.merge_tindeq_sessions(
      array[
        '94200000-0000-0000-0000-000000000011'::uuid,
        '94200000-0000-0000-0000-000000000012'::uuid
      ],
      '94200000-0000-0000-0000-000000000011'::uuid,
      6,
      false
    )
  $q$,
  'P0001',
  'merge rejected: session not found',
  'RLS: a foreign caller cannot merge another account''s sessions'
);

-- Back to A: the rejected foreign attempt changed nothing.
select set_config(
  'request.jwt.claim.sub',
  '94200000-0000-0000-0000-000000000001',
  true
);
select is(
  (
    select count(*)::integer
    from public.sessions
    where user_id = '94200000-0000-0000-0000-000000000001'
      and deleted_at is null
  ),
  3,
  'RLS: the caller''s merged state survived the foreign attempt'
);

select * from finish();
rollback;
