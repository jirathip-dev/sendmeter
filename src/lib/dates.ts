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
