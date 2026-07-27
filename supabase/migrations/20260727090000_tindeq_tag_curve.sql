-- Issue #280: persist the fitted force–duration curve params per tag so the
-- WATCH can predict a session's RPE from W' depletion. The curve is fitted on
-- the phone/web (`src/lib/force-curve.ts`, needs the raw sample streams); the
-- watch can't refit it and doesn't need to — two numbers are enough for
-- `d = max(0, peak - CF)·T / W'`.
--
-- These live on the existing SL-92 registry, which already describes itself as
-- the lightweight per-user metadata table for a tag (tags themselves stay
-- denormalized on tindeq_recordings.tag). All four columns are nullable: a tag
-- has no curve until it has enough long holds to fit one (FIT_MIN_POINTS), and
-- a missing curve must never block anything — it just contributes nothing to
-- the prediction.
--
-- NOTE for the write path: a registry row exists only once a tag is hidden, so
-- the curve upsert must create it — and must touch ONLY these columns, never
-- `hidden` (silently unhiding a hidden tag would be a nasty bug). PostgREST's
-- upsert sets exactly the payload's keys, so keep `hidden` out of the payload.
alter table public.tindeq_tags
  add column cf_kg double precision,
  add column w_prime_kgs double precision,
  add column curve_fitted_at timestamptz,
  add column curve_recording_count integer;
