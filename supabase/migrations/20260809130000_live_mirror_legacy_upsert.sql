-- #521 correction: distinguish a legacy partial upsert from a typed update.
--
-- PostgreSQL's ON CONFLICT DO UPDATE fills omitted columns from the existing
-- row. An old watch therefore reaches a BEFORE UPDATE trigger with the typed
-- row's run_id/sequence/event/terminal values, not the defaults from its
-- partial INSERT. Column-filtered triggers preserve that distinction: the
-- typed trigger runs only when a new client names at least one metadata
-- column, and marks the statement for the all-update legacy trigger. The
-- marker is transaction-local and consumed by the second trigger, so it
-- cannot weaken sequence ordering or leak across statements/connections.

create or replace function public.guard_live_workout_order()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  old_run uuid;
  new_run uuid;
begin
  if tg_op = 'INSERT' then
    if new.run_id is null then
      new.run_id := new.workout_id;
    end if;
    if new.status = 'ended' then
      new.terminal := true;
      new.event := 'end';
    end if;
    return new;
  end if;

  -- This trigger is UPDATE OF run_id/sequence/event/terminal, so reaching
  -- here is proof that the current client sent typed mirror metadata. The
  -- legacy trigger consumes this transaction-local marker before it applies
  -- the old wall-clock ordering path.
  perform set_config('sendmeter.live_workout_typed_update', 'on', true);

  old_run := coalesce(old.run_id, old.workout_id);
  new_run := coalesce(new.run_id, new.workout_id);

  if new.run_id is null then
    new.run_id := new.workout_id;
    new_run := new.run_id;
  end if;

  if new.status = 'ended' then
    new.terminal := true;
    new.event := 'end';
  end if;

  -- Terminal state dominates every later live packet from the same typed
  -- run, but a newer run may replace a terminal singleton row.
  if (old.terminal or old.status = 'ended') and new_run = old_run then
    return old;
  end if;

  if new_run = old_run then
    if new.sequence <= old.sequence then
      return old;
    end if;
  elsif new.started_at < old.started_at then
    -- UUIDs are opaque; started_at is the mixed-version run ordering signal.
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.guard_live_workout_legacy_order()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  old_run uuid;
  typed_update boolean;
begin
  -- The typed trigger runs first alphabetically and sets this only for an
  -- UPDATE that explicitly names run_id/sequence/event/terminal. Consume it
  -- even when the typed guard returned OLD for a stale packet.
  typed_update := coalesce(
    current_setting('sendmeter.live_workout_typed_update', true),
    'off'
  ) = 'on';
  perform set_config('sendmeter.live_workout_typed_update', 'off', true);
  if typed_update then
    return new;
  end if;

  old_run := coalesce(old.run_id, old.workout_id);

  -- This is the actual pre-#521 upsert shape: workout_id changes are the
  -- only legacy signal that a new run began, and no metadata column was
  -- named by the UPDATE statement.
  if new.workout_id <> old.workout_id then
    if new.started_at < old.started_at then
      return old;
    end if;
    new.run_id := new.workout_id;
    new.sequence := 0;
    new.event := case when new.status = 'ended' then 'end' else 'telemetry' end;
    new.terminal := (new.status = 'ended');
    return new;
  end if;

  new.run_id := old_run;

  -- End remains dominant for old clients too. A partial legacy End after a
  -- typed sequence-5 row preserves that sequence while making the row
  -- terminal; omitted conflict columns are not reset to zero here.
  if old.terminal or old.status = 'ended' then
    return old;
  end if;
  if new.status = 'ended' then
    new.terminal := true;
    new.event := 'end';
    return new;
  end if;

  -- Legacy live heartbeats have no sequence of their own. Their only
  -- ordering signal is updated_at; keep the typed sequence already stored on
  -- the row so a later typed duplicate/stale sequence is still rejected.
  if new.updated_at <= old.updated_at then
    return old;
  end if;
  new.event := 'telemetry';
  new.terminal := false;
  return new;
end;
$$;

drop trigger if exists live_workouts_order_guard on public.live_workouts;
drop trigger if exists a_live_workouts_typed_order_guard on public.live_workouts;
drop trigger if exists z_live_workouts_legacy_order_guard on public.live_workouts;

-- Trigger names intentionally establish the order used by the transaction-
-- local marker: typed first, legacy second.
create trigger a_live_workouts_typed_order_guard
before insert or update of run_id, sequence, event, terminal
on public.live_workouts
for each row execute function public.guard_live_workout_order();

create trigger z_live_workouts_legacy_order_guard
before update on public.live_workouts
for each row execute function public.guard_live_workout_legacy_order();
