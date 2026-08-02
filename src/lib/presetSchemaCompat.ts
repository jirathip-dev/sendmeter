type QueryResult<T> = {
  data: T | null;
  error: { message: string; code?: unknown } | null;
};

type PostgrestErrorLike = {
  code?: unknown;
  message?: unknown;
};

function isMissingTableColumn(
  error: unknown,
  table: string,
  columns: readonly string[],
): boolean {
  if (typeof error !== "object" || error === null) return false;
  const { code, message } = error as PostgrestErrorLike;
  if (typeof code !== "string" || typeof message !== "string") return false;
  const names = columns.join("|");
  if (code === "42703") {
    return new RegExp(`${table}["']?\\s*\\.\\s*["']?(?:${names})\\b`, "i").test(message) &&
      /\bdoes not exist\b/i.test(message);
  }
  return code === "PGRST204" && new RegExp(
    `could not find the ['"](?:${names})['"] column of ['"]${table}['"] in the schema cache`,
    "i",
  ).test(message);
}

const RECORDING_MODALITY_COLUMNS = [
  "capacity_evidence",
  "completed_reps",
  "completion_status",
] as const;

const TAG_REVERSE_CURVE_COLUMNS = [
  "reverse_cf_kg",
  "reverse_w_prime_kgs",
  "reverse_curve_fitted_at",
  "reverse_curve_recording_count",
] as const;

export function isMissingRecordingModalityColumn(error: unknown): boolean {
  return isMissingTableColumn(
    error,
    "tindeq_recordings",
    RECORDING_MODALITY_COLUMNS,
  );
}

export function isMissingTagReverseCurveColumn(error: unknown): boolean {
  return isMissingTableColumn(error, "tindeq_tags", TAG_REVERSE_CURVE_COLUMNS);
}

export async function retryRecordingModalitySchema<T>(
  current: () => PromiseLike<QueryResult<T>>,
  preModality: () => PromiseLike<QueryResult<T>>,
): Promise<QueryResult<T>> {
  const result = await current();
  if (!result.error || !isMissingRecordingModalityColumn(result.error)) return result;
  return await preModality();
}

export async function retryTagReverseCurveSchema<T>(
  current: () => PromiseLike<QueryResult<T>>,
  preModality: () => PromiseLike<QueryResult<T>>,
): Promise<QueryResult<T>> {
  const result = await current();
  if (!result.error || !isMissingTagReverseCurveColumn(result.error)) return result;
  return await preModality();
}

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

const REVERSE_ACTION_PRESET_COLUMNS = [
  "protocol_mode",
  "cadence_out_s",
  "cadence_return_s",
  "tolerance_mode",
  "tolerance_value",
  "prepare_s",
  "setup_note",
] as const;

export function isMissingCapacityEvidencePresetColumn(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false;
  const { code, message } = error as PostgrestErrorLike;
  if (typeof code !== "string" || typeof message !== "string") return false;
  if (code === "42703") {
    return /tindeq_presets["']?\s*\.\s*["']?capacity_evidence\b/i.test(message) &&
      /\bdoes not exist\b/i.test(message);
  }
  return code === "PGRST204" &&
    /could not find the ['"]capacity_evidence['"] column of ['"]tindeq_presets['"] in the schema cache/i.test(message);
}

export function isMissingReverseActionPresetColumn(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false;
  const { code, message } = error as PostgrestErrorLike;
  if (typeof code !== "string" || typeof message !== "string") return false;
  const names = REVERSE_ACTION_PRESET_COLUMNS.join("|");
  if (code === "42703") {
    return new RegExp(`tindeq_presets["']?\\s*\\.\\s*["']?(?:${names})\\b`, "i").test(
      message,
    ) && /\bdoes not exist\b/i.test(message);
  }
  return (
    code === "PGRST204" &&
    new RegExp(
      `could not find the ['"](?:${names})['"] column of ['"]tindeq_presets['"] in the schema cache`,
      "i",
    ).test(message)
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

/// Four schema generations can briefly exist during append-only rollout:
/// current (#422 capacity evidence), #400 Reverse Action, pre-Reverse (varied
/// holds), and pre-varied-holds. Preserve every supported generation and only
/// fall back for the specific missing-column errors above.
export async function retryPresetSchema<T>(
  current: () => PromiseLike<QueryResult<T>>,
  preCapacity: () => PromiseLike<QueryResult<T>>,
  preReverse: () => PromiseLike<QueryResult<T>>,
  legacy: () => PromiseLike<QueryResult<T>>,
): Promise<QueryResult<T>> {
  const currentResult = await current();
  if (!currentResult.error) return currentResult;
  if (isMissingPresetHoldsColumn(currentResult.error)) return await legacy();
  if (isMissingCapacityEvidencePresetColumn(currentResult.error)) {
    const preCapacityResult = await preCapacity();
    if (!preCapacityResult.error) return preCapacityResult;
    if (isMissingPresetHoldsColumn(preCapacityResult.error)) return await legacy();
    if (!isMissingReverseActionPresetColumn(preCapacityResult.error)) {
      return preCapacityResult;
    }
  } else if (!isMissingReverseActionPresetColumn(currentResult.error)) {
    return currentResult;
  }
  const preReverseResult = await preReverse();
  if (
    preReverseResult.error &&
    isMissingPresetHoldsColumn(preReverseResult.error)
  ) {
    return await legacy();
  }
  return preReverseResult;
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

export const REVERSE_ACTION_REQUIRES_MIGRATION =
  "This server does not support Reverse Action presets yet. An administrator must apply the reverse_action_protocol migration before this preset can be saved.";

type ReverseActionPresetRow = {
  protocol_mode: string;
  cadence_out_s: number;
  cadence_return_s: number;
  tolerance_mode: string;
  tolerance_value: number;
  prepare_s: number;
  setup_note: string;
};

/// Remove the #400 columns only for an ordinary hold preset whose values are
/// the migration defaults. Reverse Action behavior/setup must never be
/// silently collapsed during a deploy race.
export function preReversePresetRow<Row extends ReverseActionPresetRow>(
  row: Row,
): Omit<Row, keyof ReverseActionPresetRow> {
  const {
    protocol_mode: protocolMode,
    cadence_out_s: cadenceOutS,
    cadence_return_s: cadenceReturnS,
    tolerance_mode: toleranceMode,
    tolerance_value: toleranceValue,
    prepare_s: prepareS,
    setup_note: setupNote,
    ...preReverse
  } = row;
  if (
    protocolMode !== "hold" ||
    cadenceOutS !== 3 ||
    cadenceReturnS !== 3 ||
    toleranceMode !== "percent" ||
    toleranceValue !== 10 ||
    prepareS !== 5 ||
    setupNote !== ""
  ) {
    throw new Error(REVERSE_ACTION_REQUIRES_MIGRATION);
  }
  return preReverse;
}

export const CAPACITY_EVIDENCE_REQUIRES_MIGRATION =
  "This server does not support Reverse Action capacity evidence yet. An administrator must apply the reverse_action_modalities_and_cadence migration before this preset can be saved.";

/// Remove only #422's opt-in field for a server that already supports #400.
/// False is the schema default and can be represented faithfully; true must
/// never disappear during a deploy race.
export function preCapacityPresetRow<Row extends { capacity_evidence: boolean }>(
  row: Row,
): Omit<Row, "capacity_evidence"> {
  const { capacity_evidence: capacityEvidence, ...preCapacity } = row;
  if (capacityEvidence) throw new Error(CAPACITY_EVIDENCE_REQUIRES_MIGRATION);
  return preCapacity;
}
