#!/usr/bin/env bash
set -euo pipefail

# #802 AC4: deterministic two-session race regression for
# public.upsert_health_metrics_with_precedence.
#
# DETERMINISTIC STAGING (per the review blocker):
#   1. setup: fixture user + the PHONE writer's row, committed — the writer
#      that won the race.
#   2. holder (background): begin, take the per-date ADVISORY LOCK (the
#      exact key the RPC uses), hold it for 10s, commit.
#   3. pgTAP main session (via `supabase test db`, same server): RPC#1 while
#      the lock is held — the FIXED RPC blocks (statement_timeout 57014);
#      the unfixed RPC takes no lock and completes (the discriminating
#      assertion fails on the unfixed RPC). RPC#2 then re-runs the delayed
#      watch pass: it blocks on the same lock until the holder releases it,
#      so it is STRUCTURALLY ordered after the phone row's commit, and must
#      RETAIN the phone row (no overwrite).
#
# The advisory lock makes every interleaving lock-ordered, not timed.

set -u
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Supabase's db container is always named supabase_db_<project-ref>; run the
# setup/helper sessions through it so no host psql/dblink credentials are
# needed (Supabase's hardened images reject dblink non-superuser sessions).
container=$(docker ps --format '{{.Names}}' | grep '^supabase_db_' | head -1)
if [ -z "$container" ]; then
  echo "health-precedence-race: no running supabase db container" >&2
  exit 2
fi

USER_ID="80200000-0000-0000-0000-000000000003"
DATE="2026-01-21"
LOCK_KEY="${USER_ID}:${DATE}"

# --- Setup: fixture user (FK) + the phone writer's row, committed ---------
# (through a file in the container: heredoc-over-docker-exec stdin is not
# reliable in every runner's shell pair)
tmpdir=$(mktemp -d)
cat > "$tmpdir/setup.sql" <<SQL
delete from public.health_metrics
where user_id = '$USER_ID' and date = '$DATE';
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000',
  '$USER_ID',
  'authenticated', 'authenticated', '802-precedence-race@sendmeter.test',
  extensions.crypt('not-used', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
)
on conflict (id) do nothing;
insert into public.health_metrics (
  user_id, date, hrv_sdnn_ms, resting_hr, sleep_hours,
  sleep_deep_hours, sleep_rem_hours, body_mass_kg, resp_rate_bpm,
  readiness, zone, computed_at
) values (
  '$USER_ID', '$DATE',
  70::real, 58::real, 7.5::real, 1.4::real, 1.1::real, 69::real, 13.5::real,
  70, 'maintain', '$DATE 06:30:00+07'
)
on conflict (user_id, date) do update set
  hrv_sdnn_ms = excluded.hrv_sdnn_ms,
  resting_hr = excluded.resting_hr,
  sleep_hours = excluded.sleep_hours,
  sleep_deep_hours = excluded.sleep_deep_hours,
  sleep_rem_hours = excluded.sleep_rem_hours,
  body_mass_kg = excluded.body_mass_kg,
  resp_rate_bpm = excluded.resp_rate_bpm,
  readiness = excluded.readiness,
  zone = excluded.zone,
  computed_at = excluded.computed_at;
SQL
docker cp "$tmpdir/setup.sql" "$container:/tmp/sendmeter-race-setup.sql"
docker exec "$container" psql -U postgres -qAt -v ON_ERROR_STOP=1 -f /tmp/sendmeter-race-setup.sql
rm -rf "$tmpdir"

# --- Holder: the per-date advisory lock (absent-key case is locked too) ---
# Backgrounded foreground exec: the holder transaction owns the lock for 10s,
# then commits + exits (waitable).
docker exec "$container" psql -U postgres -qAt -c \
  "begin; select pg_advisory_xact_lock(hashtextextended('$LOCK_KEY', 0)); select pg_sleep(10); commit;" &
holder_pid=$!
# psql may need a moment to connect and take the lock before the CLI below.
sleep 1

# --- Main pgTAP session ----------------------------------------------------
cd "$repo_root"
supabase test db --local supabase/tests/health_metrics_precedence_race.sql
status=$?

# Wait out the holder so its transaction releases the lock.
wait "$holder_pid" || true
exit "$status"
