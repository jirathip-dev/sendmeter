-- #521: make the two live-workout transports one ordered stream.
--
-- WatchConnectivity is immediate but can duplicate/reorder packets, while
-- Supabase upserts are durable but can be delayed by a previous request. The
-- watch now sends run_id/sequence/event/terminal on every row. Keep these
-- columns additive for old watch builds, and reject stale updates at the DB
-- boundary as a final defence after the actor + web reducer checks.
alter table public.live_workouts
  add column run_id uuid,
  add column sequence bigint not null default 0 check (sequence >= 0),
  add column event text not null default 'telemetry'
    check (event in ('start', 'telemetry', 'phase', 'count', 'end')),
  add column terminal boolean not null default false;

update public.live_workouts
set run_id = workout_id,
    terminal = (status = 'ended'),
    event = case when status = 'ended' then 'end' else 'telemetry' end
where run_id is null;

alter table public.live_workouts
  alter column run_id set default gen_random_uuid(),
  alter column run_id set not null;

-- Keep pre-#521 inserts/upserts valid. Their representation omits run_id, so
-- a random column default would make every old heartbeat look like a new run
-- and would also let a delayed old heartbeat replace the current metadata.
-- The trigger fills the legacy identity from workout_id instead.
alter table public.live_workouts
  alter column run_id drop default;

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

  old_run := coalesce(old.run_id, old.workout_id);
  new_run := coalesce(new.run_id, new.workout_id);

  -- An old upsert omits run_id, which reaches this trigger as NULL after the
  -- default was deliberately removed above. Preserve the legacy workout id
  -- until a current client starts a genuinely new workout.
  if new.run_id is null then
    new.run_id := new.workout_id;
    new_run := new.run_id;
  end if;

  -- A pre-#521 watch omits the new metadata on an upsert. A changed
  -- workout_id is still an unambiguous fresh run; give it the legacy identity
  -- and let the current row through even when the previous row was terminal.
  if new.workout_id <> old.workout_id then
    -- A delayed packet from a previous run also has a different workout_id;
    -- do not mistake that difference for a fresh run when its start is older
    -- than the row currently occupying this user's singleton slot.
    if new.started_at < old.started_at then
      return old;
    end if;
    if new.run_id = old_run then
      new.run_id := new.workout_id;
      new.sequence := 0;
      new.event := case when new.status = 'ended' then 'end' else 'telemetry' end;
      new.terminal := (new.status = 'ended');
    end if;
    return new;
  end if;

  -- Status is terminal even if an old client does not know the explicit
  -- terminal/event fields.
  if new.status = 'ended' then
    new.terminal := true;
    new.event := 'end';
  end if;

  -- The pre-#521 client has no sequence and therefore sends the default 0
  -- for every heartbeat, including End. Do not let the normal sequence guard
  -- discard that terminal transition; it is still protected from a later
  -- live reopen by the terminal branch below.
  if new.status = 'ended'
     and new.sequence = 0
     and not (old.terminal or old.status = 'ended')
     and new_run = old_run then
    return new;
  end if;

  -- Once End is committed, no live packet from the same run may reopen it.
  if (old.terminal or old.status = 'ended') and new_run = old_run then
    return old;
  end if;

  -- A pre-#521 client sends sequence=0 for every row. Its only ordering
  -- signal is updated_at, so two legacy rows must not go through the normal
  -- sequence comparison (0 <= 0 would otherwise reject every heartbeat
  -- after the first one). Equal timestamps are treated as a duplicate.
  if new_run = old_run and new.sequence = 0 and old.sequence = 0 then
    if new.updated_at <= old.updated_at then
      return old;
    end if;
    return new;
  end if;

  if new_run = old_run then
    if new.sequence <= old.sequence then
      return old;
    end if;
  elsif new.started_at < old.started_at then
    -- UUIDs are opaque; started_at is the only mixed-version signal that can
    -- reject a late packet from a previous run.
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists live_workouts_order_guard on public.live_workouts;
create trigger live_workouts_order_guard
before insert or update on public.live_workouts
for each row execute function public.guard_live_workout_order();
