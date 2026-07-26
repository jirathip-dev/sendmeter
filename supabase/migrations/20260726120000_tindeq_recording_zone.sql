-- #259: persist the training quality a recording was PERFORMED under, instead
-- of re-inferring it from hold duration on every read.
--
-- Until now a recording stored duration_ms and tag but no zone, so quality was
-- re-derived by the duration-only `classifyZone` (<=6s power · <=8.5s power
-- endurance · <=20s strength · >20s endurance) — while a preset is BADGED by
-- the load-aware `classifyZoneLoaded` (duration AND load). Running a preset
-- badged Strength could therefore have its holds re-classified afterwards
-- purely because the load half of that decision was discarded at save time.
--
-- NULLABLE, AND DELIBERATELY NOT BACKFILLED. A backfilled value would be an
-- inference wearing the costume of a fact: once written, nothing distinguishes
-- "performed as Strength" from "guessed Strength from a 9s hold". The whole
-- point of this change is that the guess is lossy, and unlike a nullable
-- column a backfill is not reversible. Reads fall back to `classifyZone` when
-- this is null (see src/lib/zoneHistory.ts `recordingZone`), so every existing
-- recording keeps behaving exactly as it does today — and the UI can say which
-- of the two it is looking at.
--
-- Null therefore means one of: recorded before this column existed, a freehand
-- gauge run with no protocol armed (nothing to record), or a watch recording.
alter table public.tindeq_recordings
  add column zone text
  check (zone in ('power', 'strength', 'power-endurance', 'endurance'));

comment on column public.tindeq_recordings.zone is
  'Training quality this hold was performed under, from the armed zone/preset at save time (load-aware). Null = unknown: pre-#259 row, freehand hold, or watch recording — readers fall back to inferring it from duration_ms.';
