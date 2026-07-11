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
