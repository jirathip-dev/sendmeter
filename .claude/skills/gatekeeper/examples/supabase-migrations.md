# supabase/migrations: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## bad-name

Writes `supabase/migrations/20260102_index.sql`:

```
create index notes_owner_idx on public.notes (owner);
```

The gate fails and its log prints `bad-name: not <14-digit UTC timestamp>_<lowercase_name>.sql`.

Fix: rename the file with a new timestamp newer than every migration on the base, or wrap auth.uid() as (select auth.uid()); never edit a migration the base already has. Rerun: `./.gatekeeper/run check --gate supabase/migrations`

## bad-timestamp

Writes `supabase/migrations/20261340000000_index.sql`:

```
create index notes_owner_idx on public.notes (owner);
```

The gate fails and its log prints `bad-timestamp: 20261340000000 is no real UTC time`.

Fix: rename the file with a new timestamp newer than every migration on the base, or wrap auth.uid() as (select auth.uid()); never edit a migration the base already has. Rerun: `./.gatekeeper/run check --gate supabase/migrations`

## bare-auth-uid

Writes `supabase/migrations/20260102000000_read.sql`:

```
create policy notes_read on public.notes for select using (owner = auth.uid());
```

The gate fails and its log prints `bare-auth-uid: a policy calls auth.uid() bare`.

Fix: rename the file with a new timestamp newer than every migration on the base, or wrap auth.uid() as (select auth.uid()); never edit a migration the base already has. Rerun: `./.gatekeeper/run check --gate supabase/migrations`

## duplicate-version

Writes `supabase/migrations/20260101000000_index.sql`:

```
create index notes_owner_idx on public.notes (owner);
```

The gate fails and its log prints `duplicate-version: 20260101000000 is also`.

Fix: rename the file with a new timestamp newer than every migration on the base, or wrap auth.uid() as (select auth.uid()); never edit a migration the base already has. Rerun: `./.gatekeeper/run check --gate supabase/migrations`

## older-than-base

Writes `supabase/migrations/20251231000000_index.sql`:

```
create index notes_owner_idx on public.notes (owner);
```

The gate fails and its log prints `older-than-base: not newer than the base's newest migration 20260101000000`.

Fix: rename the file with a new timestamp newer than every migration on the base, or wrap auth.uid() as (select auth.uid()); never edit a migration the base already has. Rerun: `./.gatekeeper/run check --gate supabase/migrations`
