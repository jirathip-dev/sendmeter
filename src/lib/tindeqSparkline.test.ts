import { describe, it, expect } from "vitest";
import { recentSparklineSamples } from "./tindeqSparkline";
import type { TindeqSample } from "../types";

function samples(pairs: Array<[number, number]>): TindeqSample[] {
  return pairs.map(([t, kg]) => ({ t, kg }));
}

describe("recentSparklineSamples", () => {
  it("returns [] from an empty buffer", () => {
    expect(recentSparklineSamples([])).toEqual([]);
  });

  it("keeps a short buffer whole when it fits the window", () => {
    const input = samples([
      [0, 10],
      [500, 12],
      [1_000, 14],
    ]);
    expect(recentSparklineSamples(input, 10_000)).toEqual([
      { atMs: 0, kg: 10 },
      { atMs: 500, kg: 12 },
      { atMs: 1_000, kg: 14 },
    ]);
  });

  it("trims to the rolling window anchored on the last sample", () => {
    const input = samples([
      [0, 10],
      [5_000, 12],
      [9_000, 14],
      [9_500, 15],
      [10_000, 16],
    ]);
    // Window: last.t - 10s = 0 → all kept at the boundary.
    expect(recentSparklineSamples(input, 10_000).map((s) => s.atMs)).toEqual([
      0, 5_000, 9_000, 9_500, 10_000,
    ]);
  });

  it("drops samples older than the window", () => {
    const input = samples([
      [0, 10],
      [1_000, 11],
      [9_000, 14],
      [9_500, 15],
      [10_000, 16],
    ]);
    expect(recentSparklineSamples(input, 5_000).map((s) => s.atMs)).toEqual([
      9_000, 9_500, 10_000,
    ]);
  });

  it("never fabricates points and keeps ordering", () => {
    const input = samples([
      [1_000, 11],
      [2_000, 13],
      [3_000, 12],
    ]);
    const out = recentSparklineSamples(input, 1_000);
    expect(out).toEqual([
      { atMs: 2_000, kg: 13 },
      { atMs: 3_000, kg: 12 },
    ]);
    expect(out.map((s) => s.kg)).toEqual([13, 12]);
  });
});
