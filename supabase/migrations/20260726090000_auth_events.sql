-- Issue #202: the on-device auth-diagnostics ring, pushed off the device.
--
-- The logout under investigation happens overnight and the phone can't be
-- read the next morning without a debugger — and if iOS wipes the WebView's
-- website data, the local evidence goes with the session. This table is where
-- the ring lands on the next successful sign-in.
--
-- Purely observational: nothing in the app reads these rows back, and a failed
-- write is swallowed by the client (see src/lib/authEventFlush.ts), so this
-- can never affect signing in.
create table public.auth_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  -- Mirrors NullSessionReason: network-error | revoked | storage-missing |
  -- storage-unavailable | user-signed-out | storage-wiped. Text, not an enum:
  -- an old build must keep being able to report a reason a newer schema
  -- doesn't know yet (and vice versa) rather than have its upload rejected.
  reason text not null,
  -- get-session | auth-state-change | init — "we asked and got null" vs
  -- "auth-js signed us out" is the distinction #202 exists to capture.
  source text,
  -- The auth-js event name (SIGNED_OUT, TOKEN_REFRESHED, …) when source is
  -- auth-state-change.
  auth_event text,
  -- Consecutive occurrences collapsed into this incident on the device.
  occurrences integer not null default 1,
  first_at timestamptz not null,
  last_at timestamptz not null,
  -- Last-known-good session heartbeat at the moment the incident started, so
  -- a row reads "valid at 23:40, expiring 00:40, gone at 06:50, cause X".
  last_good_at timestamptz,
  last_good_expires_at timestamptz,
  -- "1.4.0 (57)" — which build produced the record.
  app_build text,
  -- preferences | local-storage | unavailable: which store held the ring.
  event_store text,
  created_at timestamptz not null default now(),
  -- Idempotency. The device re-sends the whole ring on every sign-in with
  -- growing occurrences/last_at, so the client upserts on this key and the
  -- same incident updates its row instead of duplicating. (first_at is
  -- device-assigned and stable for the life of an incident.)
  unique (user_id, reason, first_at)
);

create index auth_events_user_idx on public.auth_events (user_id, first_at desc);

alter table public.auth_events enable row level security;

-- Own rows only, same shape as every other table here. Update is granted
-- because the upsert above resolves conflicts with an UPDATE; without it
-- PostgREST rejects the whole batch. Delete is deliberately NOT granted —
-- these rows are evidence.
create policy "own auth events select" on public.auth_events
  for select using (auth.uid() = user_id);
create policy "own auth events insert" on public.auth_events
  for insert with check (auth.uid() = user_id);
create policy "own auth events update" on public.auth_events
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
