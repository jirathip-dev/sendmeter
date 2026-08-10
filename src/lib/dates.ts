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

/// Whole local days from today to `date` (negative = past). Rounded, so a DST
/// boundary (a 23h or 25h "day") still counts as one day.
export function dayOffsetFromToday(date: string): number {
  const ms = parseLocalDate(date).getTime() - parseLocalDate(today()).getTime();
  return Math.round(ms / 86400000);
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

/// Training-block age (issue #544) from a canonical local start date to
/// today, inclusive Day-1 semantics — the start date itself is Day 1, using
/// local calendar dates (`dayOffsetFromToday`), never raw elapsed seconds.
/// Fails safely (returns `null`, never a negative/bogus day count) when
/// `startDate` is malformed or in the future — a block can't have aged
/// before it started.
export function blockAge(startDate: string): BlockAge | null {
  const offset = dayOffsetFromToday(startDate); // startDate - today, in days
  if (!Number.isFinite(offset) || offset > 0) return null;
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
