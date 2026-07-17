-- Preset targets as % of PR (the exercise's best recorded peak), with an
-- optional per-set ramp: set N target = (target_pct + (N-1)*pct_step)% of PR.
-- When target_pct is set it overrides the absolute target_kg.
alter table public.tindeq_presets
  add column target_pct real check (target_pct > 0 and target_pct <= 150),
  add column pct_step real not null default 0 check (pct_step between 0 and 50);
