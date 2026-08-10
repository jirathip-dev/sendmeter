export function dateStr(d: Date): string {
  // Local time, not toISOString() — UTC would shift dates before 07:00 in UTC+7
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${day}`;
}

export function today(): string {
  return dateStr(new Date());
}

export function daysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return dateStr(d);
}

export function daysAhead(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() + n);
  return dateStr(d);
}

/// Local midnight for a "YYYY-MM-DD" date — never `new Date(str)`, which
/// parses a bare date as UTC and lands on the previous day west of Greenwich.
export function parseLocalDate(date: string): Date {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(y!, m! - 1, d!, 0, 0, 0, 0);
}

/// Whole local days from `a` to `b` (negative = `a` before `b`). Rounded, so a
/// DST boundary (a 23h or 25h "day") still counts as one day — the raw hour
/// count is off by at most 1h either side of a transition, never enough to
/// tip a `round()` over a whole-day threshold. `Math.floor` does NOT have
/// this property: on a 25h fall-back span it under-counts by a day (see
/// `blockAge`'s tests), so every local-day diff in this module routes through
/// here rather than re-deriving its own.
function localDayDiff(a: string, b: string): number {
  const ms = parseLocalDate(a).getTime() - parseLocalDate(b).getTime();
  return Math.round(ms / 86400000);
}

/// Whole local days from today to `date` (negative = past).
export function dayOffsetFromToday(date: string): number {
  return localDayDiff(date, today());
}

export interface BlockAge {
  /// Total elapsed days since the block started, inclusive — the start date
  /// itself is Day 1.
  totalDays: number;
  /// 1-based week number within the block (days 1-7 are week 1, 8-14 week 2, ...).
  week: number;
  /// 1-based day-of-week within `week` (1-7).
  dayOfWeek: number;
}

/// Training-block age (issue #544) from a canonical local start date to an
/// explicit `referenceDate` (both "YYYY-MM-DD"), inclusive Day-1 semantics —
/// the start date itself is Day 1, using local calendar dates, never raw
/// elapsed seconds. Takes `referenceDate` as an argument rather than reading
/// `today()`/`new Date()` itself, so it's a genuinely pure function a caller
/// can memoize on and test without faking the system clock — CLAUDE.md's
/// "no impure calls in render" rule, applied to the helper itself rather than
/// just its call sites.
/// Fails safely (returns `null`, never a negative/bogus day count) for a
/// `startDate` that is in the future relative to `referenceDate`, or is not a
/// real calendar date in canonical `YYYY-MM-DD` form — checked by round-
/// tripping through `dateStr`, which rejects both unparseable strings
/// (`""`, `"not-a-date"` parse to `Invalid Date`) and parseable-but-invalid
/// ones `Date` silently rolls over instead of rejecting (`"2026-02-31"` →
/// Mar 3; unpadded `"2026-7-25"`; two-digit years, which `Date` maps into
/// 1900-1999).
export function blockAge(startDate: string, referenceDate: string): BlockAge | null {
  if (dateStr(parseLocalDate(startDate)) !== startDate) return null;
  const offset = localDayDiff(startDate, referenceDate); // startDate - referenceDate, in days
  if (offset > 0) return null;
  const totalDays = -offset + 1;
  const week = Math.floor((totalDays - 1) / 7) + 1;
  const dayOfWeek = ((totalDays - 1) % 7) + 1;
  return { totalDays, week, dayOfWeek };
}

/// How a nearby day is named in prose: "yesterday" / "today" / "tomorrow" /
/// the plain weekday inside the coming week. Past ~6 days out a bare weekday
/// is ambiguous (which Thursday?), so it falls back to a short date.
export function relativeDayLabel(date: string): string {
  const offset = dayOffsetFromToday(date);
  if (offset === -1) return "yesterday";
  if (offset === 0) return "today";
  if (offset === 1) return "tomorrow";
  const d = parseLocalDate(date);
  if (offset > 1 && offset <= 6) {
    return d.toLocaleDateString(undefined, { weekday: "long" });
  }
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/// Local-day boundaries for a "YYYY-MM-DD" date, as ISO instants suitable for
/// range-querying a `timestamptz` column against a LOCAL calendar day (the
/// Gregorian/local-date rule in CLAUDE.md — never toISOString()-derive the
/// day itself, that shifts before 07:00 in UTC+7). `end` is exclusive: the
/// start of the next local day.
export function localDayRange(date: string): { start: string; end: string } {
  const [y, m, d] = date.split("-").map(Number);
  const start = new Date(y!, m! - 1, d!, 0, 0, 0, 0);
  const end = new Date(y!, m! - 1, d! + 1, 0, 0, 0, 0);
  return { start: start.toISOString(), end: end.toISOString() };
}
