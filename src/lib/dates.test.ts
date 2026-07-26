import { afterEach, describe, it, expect, vi } from "vitest";
import {
  dateStr,
  dayOffsetFromToday,
  daysAgo,
  daysAhead,
  localDayRange,
  parseLocalDate,
  relativeDayLabel,
  today,
} from "./dates";

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

describe("daysAhead", () => {
  it("daysAhead(0) is today and daysAhead(n) is strictly later", () => {
    expect(daysAhead(0)).toBe(today());
    expect(daysAhead(7) > today()).toBe(true);
  });

  it("mirrors daysAgo across zero and rolls over months", () => {
    expect(daysAhead(-3)).toBe(daysAgo(3));
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 1, 26, 9, 0, 0));
    expect(daysAhead(3)).toBe("2026-03-01"); // 2026 is not a leap year
    vi.useRealTimers();
  });
});

describe("parseLocalDate / dayOffsetFromToday", () => {
  it("parses at LOCAL midnight, not UTC", () => {
    const d = parseLocalDate("2026-03-14");
    expect(d.getFullYear()).toBe(2026);
    expect(d.getMonth()).toBe(2);
    expect(d.getDate()).toBe(14);
    expect(d.getHours()).toBe(0);
  });

  it("counts whole days either side of today", () => {
    expect(dayOffsetFromToday(today())).toBe(0);
    expect(dayOffsetFromToday(daysAhead(4))).toBe(4);
    expect(dayOffsetFromToday(daysAgo(2))).toBe(-2);
  });
});

describe("relativeDayLabel", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("names the near days in prose", () => {
    expect(relativeDayLabel(daysAgo(1))).toBe("yesterday");
    expect(relativeDayLabel(today())).toBe("today");
    expect(relativeDayLabel(daysAhead(1))).toBe("tomorrow");
  });

  it("uses the bare weekday inside the coming week", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 2, 15, 12, 0, 0)); // Sunday
    expect(relativeDayLabel("2026-03-19")).toBe(
      parseLocalDate("2026-03-19").toLocaleDateString(undefined, { weekday: "long" }),
    );
  });

  it("falls back to a date once a weekday would be ambiguous", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 2, 15, 12, 0, 0));
    // 7 days out is the SAME weekday as today — name it by date instead.
    expect(relativeDayLabel("2026-03-22")).toBe(
      parseLocalDate("2026-03-22").toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
      }),
    );
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
