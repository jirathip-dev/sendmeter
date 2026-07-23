-- Issue #114 part 2: distinguish "never reviewed" phone auto-saves (banked at
-- the hardcoded DEFAULT_RPE = 6 until the user edits them) from a
-- user-confirmed RPE of exactly 6.0 — the SESSION RPE bar chart otherwise
-- renders both identically.
alter table public.sessions add column rpe_confirmed boolean not null default true;

-- Backfill: existing unedited phone auto-saves (still sitting at the
-- hardcoded default) start out unconfirmed; everything else (manual entries,
-- watch rows, and phone saves the user has already edited away from 6) is
-- treated as already confirmed.
update public.sessions set rpe_confirmed = false
where workout_source = 'phone' and rpe = 6;
