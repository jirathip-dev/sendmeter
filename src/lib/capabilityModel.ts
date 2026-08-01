export interface CapabilityFit { family: "hill"; cf: number; maxF: number; tau: number; p: number; sse: number }
export interface CurveDatum { windowS: number; kg: number }

/** Anchored Hill/log-logistic capability curve: F(1)=maxF, F(∞)=CF. */
export function predictCapabilityFit(fit: CapabilityFit, t: number): number {
  const scale = 1 + (1 / fit.tau) ** fit.p;
  return fit.cf + (fit.maxF - fit.cf) * scale / (1 + (t / fit.tau) ** fit.p);
}

/** Deterministic constrained grid fit; one family and two shape parameters. */
export function fitCapabilityRegression(points: CurveDatum[], cf: number | null): CapabilityFit | null {
  const data = points.filter((q) => q.windowS >= 1 && q.kg > 0);
  if (data.length < 3 || cf == null || cf <= 0) return null;
  const maxF = Math.max(...data.map((q) => q.kg));
  if (cf >= maxF) return null;
  let best: CapabilityFit | null = null;
  for (let pi = 0; pi <= 24; pi++) for (let ti = 0; ti <= 100; ti++) {
    const candidate: CapabilityFit = {
      family: "hill", cf, maxF,
      p: 0.4 + pi * 0.1,
      tau: 10 ** (-0.5 + 3 * ti / 100),
      sse: 0,
    };
    candidate.sse = data.reduce((sum, q) => sum + (q.kg - predictCapabilityFit(candidate, q.windowS)) ** 2, 0);
    if (!best || candidate.sse < best.sse) best = candidate;
  }
  return best;
}
