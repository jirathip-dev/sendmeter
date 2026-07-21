import { describe, expect, it } from "vitest";
import {
  computeSendScore,
  humidityFrictionScore,
  scorePercentile,
  tempFrictionScore,
} from "./weather";

describe("friction scorers (SL-69)", () => {
  it("temperature peaks at 6°C and falls ~6/°C", () => {
    expect(tempFrictionScore(6)).toBe(100);
    expect(tempFrictionScore(16)).toBe(40); // 10° away → -60
    expect(tempFrictionScore(30)).toBe(0); // clamped
  });
  it("humidity: drier is better", () => {
    expect(humidityFrictionScore(0)).toBe(100);
    expect(humidityFrictionScore(100)).toBe(0);
  });
  it("blends 60% temp / 40% humidity", () => {
    // temp 6°C → 100, humidity 50% → 45 → 0.6*100 + 0.4*45 = 78
    expect(computeSendScore(6, 50)).toBe(78);
  });
});

describe("scorePercentile (SL-91)", () => {
  const hist = (n: number, v: number) => Array.from({ length: n }, () => v);

  it("is null until the history is meaningful", () => {
    expect(scorePercentile(50, [])).toBeNull();
    expect(scorePercentile(50, hist(99, 40))).toBeNull();
  });

  it("is the fraction of hours scoring strictly lower", () => {
    // 100 hours: 60 below the current score, 40 at/above → 60th percentile
    const history = [...hist(60, 30), ...hist(40, 80)];
    expect(scorePercentile(50, history)).toBe(60);
  });

  it("a locally-good hot day can still rank high", () => {
    // Every historical hour scored 10 (hot/muggy); today scores 20 → top.
    expect(scorePercentile(20, hist(200, 10))).toBe(100);
  });

  it("the worst possible day ranks at 0", () => {
    expect(scorePercentile(5, hist(200, 10))).toBe(0);
  });
});
