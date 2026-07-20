-- SL-79: per-rep recordings from one guided protocol run share a run id and
-- carry their set number, so History can group them and edits can apply to a
-- whole set/run. Null for free holds and pre-existing rows.
alter table public.tindeq_recordings
  add column protocol_run_id uuid,
  add column set_no int;
