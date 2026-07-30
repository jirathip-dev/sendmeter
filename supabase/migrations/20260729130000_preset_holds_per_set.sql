-- #332: per-set hold-time variation for custom protocols. Additive only —
-- nullable column, no backfill, existing rows keep today's single-holdS
-- behaviour (the app falls back to hold_s when this is null or shorter than
-- `sets`). Check mirrors hold_s's own `between 1 and 600` bound, element-wise:
-- a subquery is illegal in a check constraint, so `1 <= all(holds_s)` /
-- `600 >= all(holds_s)` is the array form, and `array_position(..., null)` is
-- needed on top since `all()` over an array containing NULL returns unknown
-- (passes) rather than false. `array_length` itself returns NULL (not 0) for
-- an empty array, which `between` would likewise treat as passing — the
-- `coalesce(..., 0)` turns that into an explicit, failing 0.
alter table public.tindeq_presets
  add column holds_s integer[];

alter table public.tindeq_presets
  add constraint tindeq_presets_holds_s_check
  check (
    holds_s is null or (
      coalesce(array_length(holds_s, 1), 0) between 1 and 20
      and array_position(holds_s, null) is null
      and 1 <= all(holds_s)
      and 600 >= all(holds_s)
    )
  );

comment on column public.tindeq_presets.holds_s is
  'Per-set hold override (#332), index 0 = set 1. Null = use hold_s for every set (pre-#332 behaviour). Falls back to hold_s when shorter than sets. Not backfilled.';
