import { describe, it, expect } from "vitest";
import { dateStr, today, daysAgo, localDayRange } from "./dates";

describe("dateStr", () => {
  it("formats a local date as zero-padded YYYY-MM-DD", () => {
    expect(dateStr(new Date(2026, 0, 5))).toBe("2026-01-05");
    expect(dateStr(new Date(2026, 11, 31))).toBe("2026-12-31");
  });

  it("uses local time, not UTC (no off-by-one before 07:00 in UTC+7)", () => {
    // 00:30 local on Jan 2 — toISOString() would report Jan 1 in UTC+7.
    expect(dateStr(new Date(2026, 0, 2, 0, 30))).toBe("2026-01-02");
  });
});

describe("today / daysAgo", () => {
  it("today() equals dateStr(now)", () => {
    expect(today()).toBe(dateStr(new Date()));
  });

  it("daysAgo(0) is today", () => {
    expect(daysAgo(0)).toBe(today());
  });

  it("daysAgo(n) is strictly earlier for n > 0 and round-trips", () => {
    expect(daysAgo(7) < today()).toBe(true);
    const d = new Date();
    d.setDate(d.getDate() - 10);
    expect(daysAgo(10)).toBe(dateStr(d));
  });
});

describe("localDayRange", () => {
  it("spans exactly 24 hours", () => {
    const { start, end } = localDayRange("2026-03-14");
    expect(new Date(end).getTime() - new Date(start).getTime()).toBe(
      24 * 60 * 60 * 1000,
    );
  });

  it("start/end fall in the same local day as the input, end is exclusive", () => {
    const { start, end } = localDayRange("2026-03-14");
    expect(dateStr(new Date(start))).toBe("2026-03-14");
    // One ms before the exclusive end is still the 14th; end itself rolls
    // into the 15th.
    expect(dateStr(new Date(new Date(end).getTime() - 1))).toBe("2026-03-14");
    expect(dateStr(new Date(end))).toBe("2026-03-15");
  });

  it("handles month/year rollover", () => {
    const { end } = localDayRange("2026-12-31");
    expect(dateStr(new Date(end))).toBe("2027-01-01");
  });
});
