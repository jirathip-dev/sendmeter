-- Smart / more-correct force targets for hang presets (SL-62):
--  * pct_basis — resolve target_pct against the max peak (PR) OR critical force (CF).
--  * target_curve — derive the load automatically from the exercise's
--    force-duration curve at hold_s (F = CF + W'/t), i.e. the force sustainable
--    for exactly that hold.
alter table public.tindeq_presets
  add column pct_basis text not null default 'pr' check (pct_basis in ('pr', 'cf')),
  add column target_curve boolean not null default false;

comment on column public.tindeq_presets.pct_basis is 'Reference for target_pct: pr = best recorded peak, cf = critical force.';
comment on column public.tindeq_presets.target_curve is 'Smart target: derive the load from the exercise force-duration curve at hold_s (CF + W''/t).';
