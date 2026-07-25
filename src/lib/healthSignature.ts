/// Pure comparison of two `fetchTodayHealthSignature()` results, split into
/// its own zero-dependency module so it's unit-testable without pulling in
/// Supabase/Capacitor (#146) — `healthSync.ts` imports `repo/health.ts`,
/// which instantiates a real Supabase client at module scope, so a test file
/// importing this logic straight out of `healthSync.ts` would drag that
/// client construction in too.
///
/// `undefined` means a signature fetch itself failed (network/read error)
/// rather than returning a real "no row"/`null` result — that's genuinely
/// unknown, not "definitely different", so it's treated as equal (no change)
/// to fail closed: a comparison failure suppresses the toast instead of
/// risking a false positive that would reintroduce the spam this fix is for.
export function healthSignaturesEqual(
  before: string | null | undefined,
  after: string | null | undefined,
): boolean {
  if (before === undefined || after === undefined) return true;
  return before === after;
}
