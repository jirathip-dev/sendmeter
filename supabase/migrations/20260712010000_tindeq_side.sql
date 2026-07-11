-- Left/right as a structured field instead of being baked into the tag,
-- so "FDP" left vs right trend separately without free-text mismatch.

alter table public.tindeq_recordings
  add column side text not null default ''
  check (side in ('', 'left', 'right', 'both'));
