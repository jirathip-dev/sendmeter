export interface CapabilityFit { family: "hill"; cf: number; maxF: number; tau: number; p: number; sse: number }
export interface CurveDatum { windowS: number; kg: number }

/** Anchored Hill/log-logistic capability curve: F(1)=maxF, F(∞)=CF. */
export function predictCapabilityFit(fit: CapabilityFit, t: number): number {
  const scale = 1 + (1 / fit.tau) ** fit.p;
  return fit.cf + (fit.maxF - fit.cf) * scale / (1 + (t / fit.tau) ** fit.p);
}

/**
 * Deterministic constrained grid fit; one family and two shape parameters.
 *
 * #488/#489: this is the 25×101-candidate grid search that made
 * `computeForceCurve` cost ~2s of main-thread work per call (it runs once
 * per bootstrap iteration — see the comment on `bootstrapSamples` in
 * force-curve.ts). This version computes the exact same SSE for the exact
 * same 2525 (p, tau) candidates in the exact same order — same result,
 * bit-for-bit, INCLUDING every degenerate case (all-NaN/all-non-finite SSE,
 * 0/1/2 points, extreme windows/loads) — without the redundant work the
 * original repeated per grid candidate:
 *   - `predictCapabilityFit`'s `scale = 1 + (1/tau)**p` term depends only on
 *     (tau, p), not on the data point being scored, but the original called
 *     `predictCapabilityFit` (which recomputes `scale`) once per DATA POINT
 *     per candidate — i.e. `scale` was recomputed ~12x more often than it
 *     needed to be. Hoisted here to once per candidate.
 *   - the original allocated a full `CapabilityFit` object for every one of
 *     the 2525 candidates just to read `.sse` back out and mostly discard
 *     it; this keeps scalars until a candidate actually wins.
 * Verified bit-for-bit (raw IEEE-754 field comparison, not just `===`)
 * against the original on 3019 fixtures: 3000 randomized plus 19 adversarial
 * (0/1/2 points, all-equal loads, all-equal windows, `cf === maxF`, `cf`
 * null/negative/1e-300, windows 1e300/NaN/Infinity, kg
 * 1e300/1e308/Infinity/NaN/denormal). An earlier version of this rewrite
 * seeded `bestSse = Infinity` and only accepted `sse < bestSse`, which is
 * NOT equivalent to the original's `!best || candidate.sse < best.sse`: when
 * every candidate scores non-finite SSE (all-NaN or all-Infinity — an
 * unreachable input for `fitCapabilityRegression` as called from
 * `computeForceCurve`, since an infinite/NaN `kg` makes the earlier linear
 * regression produce `cf = null`, which early-returns above before this
 * function is ever entered — but reachable calling this function directly,
 * as some tests do), the original ALWAYS returns the first grid candidate
 * (`p: 0.4, tau: 10**-0.5`) because `!best` is true on the very first
 * iteration regardless of its `sse`; a bare `sse < bestSse` comparison never
 * accepts a non-finite `sse` and silently returns `{p: 0, tau: 0}` instead —
 * a worse degenerate value (`predictCapabilityFit` divides by `tau`, so
 * `tau: 0` is strictly worse than a merely-nonsensical finite `tau`). The
 * `first` flag below restores the original's unconditional-first-candidate
 * semantics exactly.
 * Do not reintroduce either the redundant work or the `sse < bestSse`-only
 * comparison — this function is the single hottest loop in the force-curve
 * stack (invoked up to `1 + bootstrapSamples` times per `computeForceCurve`
 * call, 3x per Stop in ForceView).
 */
export function fitCapabilityRegression(points: CurveDatum[], cf: number | null): CapabilityFit | null {
  const data = points.filter((q) => q.windowS >= 1 && q.kg > 0);
  if (data.length < 3 || cf == null || cf <= 0) return null;
  const maxF = Math.max(...data.map((q) => q.kg));
  if (cf >= maxF) return null;
  const span = maxF - cf;
  let bestSse = Infinity;
  let bestP = 0;
  let bestTau = 0;
  let first = true;
  for (let pi = 0; pi <= 24; pi++) {
    const p = 0.4 + pi * 0.1;
    for (let ti = 0; ti <= 100; ti++) {
      const tau = 10 ** (-0.5 + 3 * ti / 100);
      const scale = 1 + (1 / tau) ** p;
      let sse = 0;
      for (const q of data) {
        const predicted = cf + span * scale / (1 + (q.windowS / tau) ** p);
        const err = q.kg - predicted;
        sse += err * err;
      }
      // `first ||` mirrors the original's `!best ||`: the very first grid
      // candidate always wins its slot, even with a non-finite `sse` — see
      // the doc comment above for why this matters.
      if (first || sse < bestSse) {
        bestSse = sse;
        bestP = p;
        bestTau = tau;
        first = false;
      }
    }
  }
  return { family: "hill", cf, maxF, p: bestP, tau: bestTau, sse: bestSse };
}
