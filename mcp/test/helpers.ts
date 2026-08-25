/// Shared test helpers.

export function day(daysBack: number): string {
  const d = new Date();
  d.setDate(d.getDate() - daysBack);
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${dd}`;
}
