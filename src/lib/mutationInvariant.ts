/**
 * A mutation scoped to one known row completed without a database error but
 * returned no row. PostgREST can do this when an UPDATE/DELETE is filtered to
 * zero rows (including an unexpectedly-silent RLS policy), so treating the
 * response as success would leave the UI out of sync with durable state.
 */
export class ZeroRowMutationError extends Error {
  readonly affectedRows = 0;

  constructor() {
    super("Mutation completed without affecting the expected row");
    this.name = "ZeroRowMutationError";
  }
}

/** Unwrap a mutation that must return exactly one row. */
export function unwrapOneMutation<T>(result: {
  data: T | null;
  error: unknown | null;
}): T {
  if (result.error) throw result.error;
  if (result.data === null) throw new ZeroRowMutationError();
  return result.data;
}

export function isZeroRowMutationError(
  error: unknown,
): error is ZeroRowMutationError {
  if (error instanceof ZeroRowMutationError) return true;
  // Vitest module resets, duplicated bundles, and cross-realm errors can each
  // produce the same controlled error from a different constructor identity.
  // Match only the two constants this class owns — never a database message.
  if (typeof error !== "object" || error === null) return false;
  const value = error as Record<string, unknown>;
  return value.name === "ZeroRowMutationError" && value.affectedRows === 0;
}
