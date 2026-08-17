-- Local-dev seed (applied by `supabase start` / `supabase db reset` — never
-- runs against the remote project). One test user with ~6 weeks of plausible
-- history so every card has data: ACWR/load, readiness trend, phase banner,
-- an auto-tracked watch workout, and Tindeq recordings with a trend.
--
--   email:    dev@sendmeter.test
--   password: devpassword

-- ── API-role grants ──────────────────────────────────────────────────────────
-- The current local postgres image ships hardened default privileges: tables
-- created by migrations are NOT auto-granted to anon/authenticated (the hosted
-- project predates that hardening and has full grants). Mirror the hosted
-- state locally; RLS stays the actual security boundary.

grant select, insert, update, delete on all tables in schema public
  to anon, authenticated, service_role;
grant usage, select on all sequences in schema public
  to anon, authenticated, service_role;
alter default privileges in schema public
  grant select, insert, update, delete on tables to anon, authenticated, service_role;

-- ── Auth user ────────────────────────────────────────────────────────────────
-- GoTrue reads these tables directly; empty-string token columns (not null)
-- keep its scans happy. Password hashing via pgcrypto in the extensions schema.

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000',
  '11111111-1111-1111-1111-111111111111',
  'authenticated', 'authenticated',
  'dev@sendmeter.test',
  extensions.crypt('devpassword', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
);

insert into auth.identities (
  id, user_id, provider_id, identity_data, provider,
  last_sign_in_at, created_at, updated_at
) values (
  gen_random_uuid(),
  '11111111-1111-1111-1111-111111111111',
  '11111111-1111-1111-1111-111111111111',
  jsonb_build_object(
    'sub', '11111111-1111-1111-1111-111111111111',
    'email', 'dev@sendmeter.test',
    'email_verified', true
  ),
  'email', now(), now(), now()
);

-- ── Phase state ──────────────────────────────────────────────────────────────

insert into public.user_settings (user_id, current_phase, phase_start_date)
values ('11111111-1111-1111-1111-111111111111', 'strength', current_date - 9);

insert into public.phase_periods (user_id, phase, started_on, ended_on) values
  ('11111111-1111-1111-1111-111111111111', 'capacity', current_date - 37, current_date - 10),
  ('11111111-1111-1111-1111-111111111111', 'strength', current_date - 9, null);

-- ── Sessions: ~6 weeks on a Mon/Wed/Fri/Sat pattern (feeds ACWR + history) ──

insert into public.sessions (user_id, date, type, type_label, duration_min, rpe, phase)
select
  '11111111-1111-1111-1111-111111111111',
  current_date - d,
  t.type, t.type_label,
  t.duration_min + (d % 3) * 5,
  t.rpe,
  case when d <= 9 then 'strength' else 'capacity' end
from generate_series(1, 42) as d
cross join lateral (
  select * from (values
    (1, 'board',       'Board Climbing',       60, 7.5),
    (3, 'fingerboard', 'Fingerboard',          45, 6.0),
    (5, 'gym',         'Gym Session',          90, 6.5),
    (6, 'outdoor',     'Outdoor / Projecting', 150, 5.0)
  ) as v(dow, type, type_label, duration_min, rpe)
  where v.dow = extract(dow from current_date - d)::int
) as t;

-- ── Health metrics: 35 daily rows with smooth pseudo-random variation ───────

insert into public.health_metrics (
  user_id, date, hrv_sdnn_ms, resting_hr, sleep_hours, sleep_deep_hours,
  sleep_rem_hours, resp_rate_bpm, body_mass_kg, readiness, zone
)
select
  '11111111-1111-1111-1111-111111111111',
  current_date - d,
  round((65 + 8 * sin(d * 1.7))::numeric, 1),
  round((52 + 2.5 * sin(d * 0.9))::numeric, 1),
  round((7.2 + 0.8 * sin(d * 1.3))::numeric, 2),
  round((1.2 + 0.3 * sin(d * 0.7))::numeric, 2),
  round((1.6 + 0.3 * cos(d * 1.1))::numeric, 2),
  round((14.5 + 0.6 * sin(d))::numeric, 1),
  round((68 + 0.4 * sin(d * 0.5))::numeric, 1),
  r.score,
  case when r.score < 50 then 'recover' when r.score >= 75 then 'push' else 'maintain' end
from generate_series(0, 34) as d
cross join lateral (
  select least(95, greatest(30, round(68 + 14 * sin(d * 1.1) + 6 * sin(d * 0.35))::int)) as score
) as r;

-- ── One auto-tracked watch workout (3 days ago) + its session row ───────────

insert into public.sessions (id, user_id, date, type, type_label, duration_min, rpe, phase, workout_source)
values (
  '22222222-2222-2222-2222-222222222222',
  '11111111-1111-1111-1111-111111111111',
  current_date - 3, 'auto', 'Auto-tracked', 95, 7, 'strength', 'watch'
);

insert into public.climb_workouts (
  id, user_id, started_at, ended_at, avg_hr, max_hr, active_kcal,
  elevation_gain_m, attempts_detected, attempts_confirmed,
  rpe_predicted, rpe_confirmed, mean_effort, attempts_per_10min, session_id, source,
  raw
) values (
  '33333333-3333-3333-3333-333333333333',
  '11111111-1111-1111-1111-111111111111',
  (current_date - 3)::timestamptz + interval '18 hours',
  (current_date - 3)::timestamptz + interval '19 hours 35 minutes',
  132, 171, 520, 210, 18, 16, 7.2, 7.0, 6.1, 1.7,
  '22222222-2222-2222-2222-222222222222', 'watch',
  -- #645: a modest trace (95 min → ~380 samples at a 15 s stride) so the HR
  -- chart can be exercised on ladder rungs 2/3 without production data.
  -- Each row is [t_s, alt_m, motion_rms, hr]; the deliberate null-hr run
  -- (t 1800–2040, a ~4 min sensor dropout mid-rest) is the AC2 fixture —
  -- the chart must break its line there, never interpolate across it.
  (
    select jsonb_agg(jsonb_build_array(
      t,
      round((10 + 8 * sin(t / 400.0))::numeric, 1),
      round((0.2 + 0.08 * abs(sin(t / 250.0)))::numeric, 3),
      case
        when t between 1800 and 2040 then null
        when t between 540 and 569 then 150
        when t between 1080 and 1113 then 154
        when t between 1620 and 1657 then 158
        when t between 2160 and 2201 then 162
        when t between 2700 and 2745 then 166
        else round((110 + 22 * sin(t / 800.0))::numeric, 1)
      end
    ))
    from generate_series(0, 5700, 15) as t
  )
);

insert into public.climb_attempts (
  workout_id, user_id, started_at, duration_s, elevation_gain_m,
  avg_hr, peak_hr, motion_intensity, effort_score, source
)
select
  '33333333-3333-3333-3333-333333333333',
  '11111111-1111-1111-1111-111111111111',
  (current_date - 3)::timestamptz + interval '18 hours' + (n * interval '9 minutes'),
  25 + n * 4, 3 + n * 0.3, 138 + n * 2, 158 + n * 2,
  0.28 + n * 0.02, 5 + n * 0.6,
  -- One manual attempt (n = 4, the watch's Boulder/Stop button) so the
  -- chart's caution shading for manual windows is exercised locally too.
  case when n = 4 then 'manual' else 'auto' end
from generate_series(1, 5) as n;

-- ── Tindeq recordings: short sessions + a force-duration ladder ───────
-- samples are [[t_ms, kg], ...] (t in MILLISECONDS — charts divide by 1000).
-- 7s holds at 10Hz: ~1.2s ramp to peak, then a plateau with slight decay.

-- The older session has a NULL zone, like every recording made before #259 —
-- its quality gets inferred from the 7s hold (power-endurance). The newer one
-- was run under an armed Strength preset and stores that, which is exactly the
-- case duration alone gets wrong: both surfaces should show the two sessions
-- classified differently despite identical holds.
with spec(days_ago, group_id, side, peak, zone) as (
  values
    (10, 'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'left',  38.0, null),
    (10, 'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'right', 40.0, null),
    ( 3, 'aaaaaaaa-0000-0000-0000-000000000002'::uuid, 'left',  40.0, 'strength'),
    ( 3, 'aaaaaaaa-0000-0000-0000-000000000002'::uuid, 'right', 42.5, 'strength')
),
curves as (
  select
    s.*,
    t,
    round((
      s.peak * least(t / 1200.0, 1.0)
      - greatest(t - 1200, 0) * 0.0015
      + 0.5 * sin(t / 180.0)
    )::numeric, 2) as kg
  from spec s
  cross join generate_series(0, 7000, 100) as t
)
insert into public.tindeq_recordings (
  user_id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count,
  samples, tag, side, group_id, zone
)
select
  '11111111-1111-1111-1111-111111111111',
  (current_date - days_ago)::timestamptz + interval '17 hours'
    + case side when 'right' then interval '3 minutes' else interval '0' end,
  7000,
  max(kg), round(avg(kg)::numeric, 2), count(*),
  jsonb_agg(jsonb_build_array(t, kg) order by t),
  'Half crimp', side, group_id, zone
from curves
group by days_ago, group_id, side, peak, zone;

-- Older 15–120s all-out holds keep the default Force tab's CF/W′ fit and
-- long-duration chart populated. They sit outside the trailing four-week
-- training-balance window, so the recent 7s classification examples above
-- remain the only recordings affecting that card. The durations span the
-- curve fit instead of fabricating long-window evidence from one hold.
with spec(days_ago, group_id, duration_s, peak, decay_per_ms) as (
  values
    (35, 'aaaaaaaa-0000-0000-0000-000000000003'::uuid,  15, 33.0, 0.00025),
    (45, 'aaaaaaaa-0000-0000-0000-000000000004'::uuid,  30, 28.0, 0.00015),
    (55, 'aaaaaaaa-0000-0000-0000-000000000005'::uuid,  60, 24.0, 0.00008),
    (65, 'aaaaaaaa-0000-0000-0000-000000000006'::uuid, 120, 21.0, 0.000035)
),
curves as (
  select
    s.*,
    t,
    round((
      s.peak * least(t / 1200.0, 1.0)
      - greatest(t - 1200, 0) * s.decay_per_ms
      + 0.25 * sin(t / 240.0)
    )::numeric, 2) as kg
  from spec s
  cross join lateral generate_series(0, s.duration_s * 1000, 100) as t
)
insert into public.tindeq_recordings (
  user_id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count,
  samples, tag, side, group_id, zone
)
select
  '11111111-1111-1111-1111-111111111111',
  (current_date - days_ago)::timestamptz + interval '17 hours',
  duration_s * 1000,
  max(kg), round(avg(kg)::numeric, 2), count(*),
  jsonb_agg(jsonb_build_array(t, kg) order by t),
  'Half crimp', 'left', group_id, null
from curves
group by days_ago, group_id, duration_s, peak, decay_per_ms;

-- ── Tindeq presets: one of each target shape the guided gauge supports ──────
insert into public.tindeq_presets (
  user_id, name, hold_s, reps, sets, rest_reps_s, rest_sets_s,
  target_kg, target_pct, pct_basis, pct_step, target_curve, alternate_sides, created_at
) values
  ('11111111-1111-1111-1111-111111111111', 'Max hangs 10s', 10, 3, 3, 60, 180,
   32, null, 'pr', 0, false, false, now() - interval '3 minutes'),
  ('11111111-1111-1111-1111-111111111111', 'Strength ramp 70-80%', 7, 2, 3, 45, 120,
   null, 70, 'pr', 5, false, false, now() - interval '2 minutes'),
  ('11111111-1111-1111-1111-111111111111', 'Repeaters L/R', 7, 6, 4, 3, 30,
   20, null, 'pr', 0, false, true, now() - interval '1 minute');

-- ── Routine presets: multi-step routines with reps + per-step rests ─────────
-- Step keys are the client's RoutineStep shape — note camelCase "restS".
insert into public.routine_presets (user_id, name, steps, created_at) values
  ('11111111-1111-1111-1111-111111111111', 'Conditioning circuit',
   '[
     {"label": "Plank",              "detail": "Hard brace, straight line",  "s": 45, "reps": 3, "restS": 15},
     {"label": "Push-ups",                                                   "s": 30, "reps": 3, "restS": 30},
     {"label": "Hanging knee raises","detail": "Slow and controlled",        "s": 30, "reps": 2, "restS": 45}
   ]'::jsonb,
   now() - interval '2 minutes'),
  ('11111111-1111-1111-1111-111111111111', 'Mobility flow',
   '[
     {"label": "Couch stretch",       "detail": "60s per side",             "s": 60, "reps": 2, "restS": 10},
     {"label": "Thoracic rotations",                                        "s": 45},
     {"label": "Shoulder dislocates", "detail": "Band, wide grip",          "s": 60}
   ]'::jsonb,
   now() - interval '1 minute');
