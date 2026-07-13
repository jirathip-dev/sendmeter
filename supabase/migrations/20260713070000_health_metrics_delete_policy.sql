-- health_metrics never got a delete policy, unlike sessions/tindeq_recordings
-- (which both support delete — first hard, then soft via
-- 20260712030000_soft_delete.sql). This was an oversight from accretion,
-- not a deliberate append-only design: a bad row (e.g. a pre-date-sanity-
-- constraint 543-years-ahead entry that predates the backfill, or a
-- duplicate) currently has no way to be removed, only overwritten via
-- update. Matches the plain hard-delete policy sessions/tindeq_recordings
-- originally shipped with, before soft delete layered on top of them —
-- health_metrics has no Trash UI, so a straightforward delete policy (not
-- soft-delete) is the right scope here.

create policy "own health delete" on public.health_metrics for delete using (auth.uid() = user_id);
