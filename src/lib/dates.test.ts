import { afterEach, describe, it, expect, vi } from "vitest";
import {
  blockAge,
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

describe("blockAge", () => {
  // Both dates are always explicit arguments now (never `today()`/`new
  // Date()` inside the helper — see its docstring), so every case below is a
  // plain two-literal call: no fake timers needed anywhere in this block.

  it("issue #544 regression: block started 25 Jul, today 10 Aug, is Day 17 / Week 3 Day 3", () => {
    expect(blockAge("2026-07-25", "2026-08-10")).toEqual({ totalDays: 17, week: 3, dayOfWeek: 3 });
  });

  it("the start date itself is Day 1, Week 1", () => {
    expect(blockAge("2026-08-10", "2026-08-10")).toEqual({ totalDays: 1, week: 1, dayOfWeek: 1 });
  });

  it("rolls from Week 1 Day 7 to Week 2 Day 1 at the week boundary", () => {
    expect(blockAge("2026-08-04", "2026-08-10")).toEqual({ totalDays: 7, week: 1, dayOfWeek: 7 });
    expect(blockAge("2026-08-03", "2026-08-10")).toEqual({ totalDays: 8, week: 2, dayOfWeek: 1 });
  });

  it("counts correctly across a month/year boundary", () => {
    // Dec 30 = Day 1, Dec 31 = Day 2, Jan 1 = Day 3.
    expect(blockAge("2025-12-30", "2026-01-01")).toEqual({ totalDays: 3, week: 1, dayOfWeek: 3 });
  });

  describe("DST transitions (America/New_York)", () => {
    afterEach(() => {
      vi.unstubAllEnvs();
    });

    it("the TZ stub actually takes effect (sanity check for the two tests below)", () => {
      vi.stubEnv("TZ", "America/New_York");
      // Post fall-back (EST, UTC-5): getTimezoneOffset is +300 minutes.
      expect(new Date(2026, 10, 2, 0, 0, 0, 0).getTimezoneOffset()).toBe(300);
      // Post spring-forward (EDT, UTC-4): +240 minutes.
      expect(new Date(2026, 2, 9, 0, 0, 0, 0).getTimezoneOffset()).toBe(240);
    });

    it("counts a whole day across the 23h spring-forward day", () => {
      vi.stubEnv("TZ", "America/New_York");
      // 2026-03-08 is 23h long in America/New_York.
      expect(blockAge("2026-03-07", "2026-03-09")).toEqual({ totalDays: 3, week: 1, dayOfWeek: 3 });
    });

    it("counts a whole day across the 25h fall-back day — the case Math.floor gets wrong", () => {
      vi.stubEnv("TZ", "America/New_York");
      // 2026-11-01 is 25h long in America/New_York: the raw ms diff between
      // local midnights Oct 31 and Nov 2 is 49h, not 48h. round(49/24) = 2
      // (correct, Day 3); floor(49/24) = 2 as well for a POSITIVE span, but
      // the offset computed here is NEGATIVE (start - reference), where
      // floor(-49/24) = -3 → Day 4, silently off by one. This is the case
      // the spring-forward test above cannot catch (there floor and round
      // agree) — see the finding this test was added for (#544 review).
      expect(blockAge("2026-10-31", "2026-11-02")).toEqual({ totalDays: 3, week: 1, dayOfWeek: 3 });
    });

    it("stays exact across a longer span that includes the fall-back transition", () => {
      vi.stubEnv("TZ", "America/New_York");
      expect(blockAge("2026-10-25", "2026-11-08")).toEqual({ totalDays: 15, week: 3, dayOfWeek: 1 });
    });
  });

  it("fails safely (null) for a future start date", () => {
    expect(blockAge("2026-08-11", "2026-08-10")).toBeNull();
  });

  it("fails safely (null) for a malformed start date", () => {
    expect(blockAge("", "2026-08-10")).toBeNull();
    expect(blockAge("not-a-date", "2026-08-10")).toBeNull();
  });

  it("fails safely (null) for a semantically-invalid but numerically-parseable start date", () => {
    // Date silently rolls these over instead of rejecting them; blockAge
    // must not render a confident-looking Day N from a date that was never
    // really valid.
    expect(blockAge("2026-02-31", "2026-08-10")).toBeNull(); // rolls to Mar 3
    expect(blockAge("2026-7-25", "2026-08-10")).toBeNull(); // unpadded month
    expect(blockAge("0001-01-01", "2026-08-10")).toBeNull(); // Date maps year 1 -> 1901
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
