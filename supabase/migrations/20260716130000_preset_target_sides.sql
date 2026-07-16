-- Preset extras: an optional target weight (drawn as the target band on the
-- live force chart) and left/right alternation between reps of the guided
-- protocol (switch hands during each rest).
alter table public.tindeq_presets
  add column target_kg real check (target_kg > 0),
  add column alternate_sides boolean not null default false;
