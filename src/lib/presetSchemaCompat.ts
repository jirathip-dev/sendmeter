type QueryResult<T> = {
  data: T | null;
  error: { message: string; code?: unknown } | null;
};

type PostgrestErrorLike = {
  code?: unknown;
  message?: unknown;
};

/// True only for the two errors PostgREST emits when the #332 `holds_s`
/// migration has not reached the server yet:
/// - PostgreSQL's undefined-column error for a select projection.
/// - PostgREST's schema-cache error for a mutation payload.
///
/// Kept deliberately narrow: auth, RLS, validation, network and other schema
/// failures must surface as-is rather than being disguised by a legacy retry.
export function isMissingPresetHoldsColumn(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false;
  const { code, message } = error as PostgrestErrorLike;
  if (typeof code !== "string" || typeof message !== "string") return false;

  if (code === "42703") {
    return (
      /tindeq_presets["']?\s*\.\s*["']?holds_s\b/i.test(message) &&
      /\bdoes not exist\b/i.test(message)
    );
  }

  return (
    code === "PGRST204" &&
    /could not find the ['"]holds_s['"] column of ['"]tindeq_presets['"] in the schema cache/i.test(
      message,
    )
  );
}

/// Run the normal query first and make exactly one legacy attempt only when
/// PostgREST says `tindeq_presets.holds_s` is absent. Mutation errors of these
/// forms are transaction failures (no row is committed), so the fallback is
/// not a duplicate insert/update.
export async function retryWithoutPresetHoldsColumn<T>(
  current: () => PromiseLike<QueryResult<T>>,
  legacy: () => PromiseLike<QueryResult<T>>,
): Promise<QueryResult<T>> {
  const result = await current();
  if (!result.error || !isMissingPresetHoldsColumn(result.error)) return result;
  return await legacy();
}

export const VARIED_HOLDS_REQUIRE_MIGRATION =
  "This server does not support varied hold times yet. Turn off “Vary hold per set” and save again; an administrator must apply the preset_holds_per_set migration before varied holds can be saved.";

/// Strip only the migrated column from an ordinary preset write. A non-null
/// list changes protocol behavior and can never be silently collapsed to the
/// base hold time.
export function legacyPresetRow<Row extends { holds_s: number[] | null }>(
  row: Row,
): Omit<Row, "holds_s"> {
  const { holds_s: holdsS, ...legacy } = row;
  if (holdsS !== null) throw new Error(VARIED_HOLDS_REQUIRE_MIGRATION);
  return legacy;
}
