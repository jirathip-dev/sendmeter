-- Tindeq recordings gain a session grouping and a per-recording tag
-- ("right hand FDP", "left rotator", ...). A gauge session = all recordings
-- sharing one client-generated group_id; no separate table needed since
-- sessions are only ever derived from their recordings. Trends filter by tag.

alter table public.tindeq_recordings
  add column group_id uuid,
  add column tag text not null default '';

create index tindeq_recordings_user_tag_idx
  on public.tindeq_recordings (user_id, tag)
  where tag <> '';
