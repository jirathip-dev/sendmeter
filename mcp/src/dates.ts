/// Local-calendar date helpers with the same semantics as the web app's
/// src/lib/dates.ts (Gregorian/local dates — never UTC-derived day strings,
/// which shift before 07:00 in UTC+7).

export function dateStr(d: Date): string {
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

/// Strict YYYY-MM-DD check (round-trips through a local Date, so
/// "2026-02-31" and unpadded values are rejected — the web's blockAge rule).
export function isDateString(s: string): boolean {
  const [y, m, d] = s.split("-").map(Number);
  if (y === undefined || m === undefined || d === undefined) return false;
  if (!Number.isInteger(y) || !Number.isInteger(m) || !Number.isInteger(d)) return false;
  const parsed = new Date(y, m - 1, d, 0, 0, 0, 0);
  return dateStr(parsed) === s;
}

/// Local-day boundaries for a "YYYY-MM-DD" date, as ISO instants for
/// range-querying a `timestamptz` column against a LOCAL calendar day
/// (mirrors the web's dates.ts localDayRange; `end` is exclusive).
export function localDayRange(date: string): { start: string; end: string } {
  const [y, m, d] = date.split("-").map(Number);
  const start = new Date(y!, m! - 1, d!, 0, 0, 0, 0);
  const end = new Date(y!, m! - 1, d! + 1, 0, 0, 0, 0);
  return { start: start.toISOString(), end: end.toISOString() };
}
