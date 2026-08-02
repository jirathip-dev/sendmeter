import { describe, expect, it, vi } from "vitest";
import {
  isMissingCapacityEvidencePresetColumn,
  isMissingPresetHoldsColumn,
  isMissingReverseActionPresetColumn,
  isMissingRecordingModalityColumn,
  isMissingTagReverseCurveColumn,
  legacyPresetRow,
  preCapacityPresetRow,
  preReversePresetRow,
  retryPresetSchema,
  retryRecordingModalitySchema,
  retryTagReverseCurveSchema,
  retryWithoutPresetHoldsColumn,
  VARIED_HOLDS_REQUIRE_MIGRATION,
} from "./presetSchemaCompat";

describe("isMissingPresetHoldsColumn (#345)", () => {
  it("recognizes PostgreSQL's missing select-projection column", () => {
    expect(
      isMissingPresetHoldsColumn({
        code: "42703",
        message: "column tindeq_presets.holds_s does not exist",
      }),
    ).toBe(true);
  });

  it("recognizes PostgREST's missing mutation-payload column", () => {
    expect(
      isMissingPresetHoldsColumn({
        code: "PGRST204",
        message:
          "Could not find the 'holds_s' column of 'tindeq_presets' in the schema cache",
      }),
    ).toBe(true);
  });

  it("does not disguise unrelated failures as a legacy-schema problem", () => {
    expect(
      isMissingPresetHoldsColumn({
        code: "42703",
        message: "column tindeq_presets.some_other_column does not exist",
      }),
    ).toBe(false);
    expect(
      isMissingPresetHoldsColumn({
        code: "42703",
        message: "column routine_presets.holds_s does not exist",
      }),
    ).toBe(false);
    expect(
      isMissingPresetHoldsColumn({
        code: "PGRST204",
        message:
          "Could not find the 'holds_s' column of 'routine_presets' in the schema cache",
      }),
    ).toBe(false);
    expect(
      isMissingPresetHoldsColumn({
        code: "42501",
        message: "permission denied for table tindeq_presets",
      }),
    ).toBe(false);
    expect(isMissingPresetHoldsColumn(new Error("Failed to fetch"))).toBe(false);
  });
});

describe("Reverse Action preset schema rollout (#400)", () => {
  it("recognizes only missing #400 columns on tindeq_presets", () => {
    expect(
      isMissingReverseActionPresetColumn({
        code: "42703",
        message: "column tindeq_presets.protocol_mode does not exist",
      }),
    ).toBe(true);
    expect(
      isMissingReverseActionPresetColumn({
        code: "PGRST204",
        message:
          "Could not find the 'cadence_out_s' column of 'tindeq_presets' in the schema cache",
      }),
    ).toBe(true);
    expect(
      isMissingReverseActionPresetColumn({
        code: "42703",
        message: "column routine_presets.protocol_mode does not exist",
      }),
    ).toBe(false);
  });

  it("preserves varied holds on the pre-Reverse schema and uses legacy only when needed", async () => {
    const reverseMissing = {
      code: "42703",
      message: "column tindeq_presets.protocol_mode does not exist",
    };
    const current = vi.fn(async () => ({ data: null, error: reverseMissing }));
    const preCapacity = vi.fn(async () => ({ data: null, error: reverseMissing }));
    const preReverse = vi.fn(async () => ({ data: ["holds"], error: null }));
    const legacy = vi.fn(async () => ({ data: ["legacy"], error: null }));
    await expect(retryPresetSchema(current, preCapacity, preReverse, legacy)).resolves.toEqual({
      data: ["holds"],
      error: null,
    });
    expect(preReverse).toHaveBeenCalledTimes(1);
    expect(legacy).not.toHaveBeenCalled();
  });

  it("strips default #400 fields from ordinary holds but never collapses Reverse Action", () => {
    const ordinary = {
      name: "Repeaters",
      protocol_mode: "hold",
      cadence_out_s: 3,
      cadence_return_s: 3,
      tolerance_mode: "percent",
      tolerance_value: 10,
      prepare_s: 5,
      setup_note: "",
    };
    expect(preReversePresetRow(ordinary)).toEqual({ name: "Repeaters" });
    expect(() =>
      preReversePresetRow({ ...ordinary, protocol_mode: "reverse_action" }),
    ).toThrow(/does not support Reverse Action/);
    expect(() => preReversePresetRow({ ...ordinary, setup_note: "red spring" })).toThrow(
      /does not support Reverse Action/,
    );
  });
});

describe("capacity-evidence preset schema rollout (#422)", () => {
  it("recognizes the specific new preset column", () => {
    expect(isMissingCapacityEvidencePresetColumn({
      code: "42703",
      message: "column tindeq_presets.capacity_evidence does not exist",
    })).toBe(true);
    expect(isMissingCapacityEvidencePresetColumn({
      code: "42703",
      message: "column tindeq_recordings.capacity_evidence does not exist",
    })).toBe(false);
  });

  it("retries against the #400 schema without losing Reverse Action", async () => {
    const missing = {
      code: "PGRST204",
      message: "Could not find the 'capacity_evidence' column of 'tindeq_presets' in the schema cache",
    };
    const current = vi.fn(async () => ({ data: null, error: missing }));
    const preCapacity = vi.fn(async () => ({ data: ["reverse"], error: null }));
    const preReverse = vi.fn(async () => ({ data: ["old"], error: null }));
    const legacy = vi.fn(async () => ({ data: ["legacy"], error: null }));
    await expect(retryPresetSchema(current, preCapacity, preReverse, legacy)).resolves.toEqual({
      data: ["reverse"],
      error: null,
    });
    expect(preReverse).not.toHaveBeenCalled();
    expect(legacy).not.toHaveBeenCalled();
  });

  it("strips only false and never silently drops explicit capacity intent", () => {
    expect(preCapacityPresetRow({ name: "Spring", capacity_evidence: false })).toEqual({
      name: "Spring",
    });
    expect(() => preCapacityPresetRow({ name: "Test", capacity_evidence: true })).toThrow(
      /capacity evidence/,
    );
  });
});

describe("Reverse Action read-schema rollout (#422)", () => {
  it("recognizes only the new recording and tag columns on their own tables", () => {
    expect(isMissingRecordingModalityColumn({
      code: "42703",
      message: "column tindeq_recordings.completed_reps does not exist",
    })).toBe(true);
    expect(isMissingRecordingModalityColumn({
      code: "42703",
      message: "column tindeq_presets.completed_reps does not exist",
    })).toBe(false);
    expect(isMissingTagReverseCurveColumn({
      code: "PGRST204",
      message: "Could not find the 'reverse_cf_kg' column of 'tindeq_tags' in the schema cache",
    })).toBe(true);
  });

  it("keeps Force reads available while the migration workflow catches up", async () => {
    const recordingMissing = {
      code: "42703",
      message: "column tindeq_recordings.capacity_evidence does not exist",
    };
    const tagMissing = {
      code: "42703",
      message: "column tindeq_tags.reverse_cf_kg does not exist",
    };
    await expect(retryRecordingModalitySchema(
      async () => ({ data: null, error: recordingMissing }),
      async () => ({ data: ["recordings"], error: null }),
    )).resolves.toEqual({ data: ["recordings"], error: null });
    await expect(retryTagReverseCurveSchema(
      async () => ({ data: null, error: tagMissing }),
      async () => ({ data: ["static"], error: null }),
    )).resolves.toEqual({ data: ["static"], error: null });
  });
});

describe("retryWithoutPresetHoldsColumn (#345)", () => {
  it("leaves migrated-schema success unchanged", async () => {
    const current = vi.fn(async () => ({ data: ["current"], error: null }));
    const legacy = vi.fn(async () => ({ data: ["legacy"], error: null }));

    await expect(retryWithoutPresetHoldsColumn(current, legacy)).resolves.toEqual({
      data: ["current"],
      error: null,
    });
    expect(current).toHaveBeenCalledTimes(1);
    expect(legacy).not.toHaveBeenCalled();
  });

  it("makes exactly one legacy attempt for a missing holds_s column", async () => {
    const missing = {
      code: "PGRST204",
      message:
        "Could not find the 'holds_s' column of 'tindeq_presets' in the schema cache",
    };
    const current = vi.fn(async () => ({ data: null, error: missing }));
    const legacy = vi.fn(async () => ({ data: ["legacy"], error: null }));

    await expect(retryWithoutPresetHoldsColumn(current, legacy)).resolves.toEqual({
      data: ["legacy"],
      error: null,
    });
    expect(current).toHaveBeenCalledTimes(1);
    expect(legacy).toHaveBeenCalledTimes(1);
  });

  it("returns unrelated errors without attempting a second mutation", async () => {
    const denied = {
      code: "42501",
      message: "permission denied for table tindeq_presets",
    };
    const current = vi.fn(async () => ({ data: null, error: denied }));
    const legacy = vi.fn(async () => ({ data: ["legacy"], error: null }));

    await expect(retryWithoutPresetHoldsColumn(current, legacy)).resolves.toEqual({
      data: null,
      error: denied,
    });
    expect(current).toHaveBeenCalledTimes(1);
    expect(legacy).not.toHaveBeenCalled();
  });
});

describe("legacyPresetRow (#345)", () => {
  it("omits holds_s and preserves every ordinary preset field", () => {
    expect(
      legacyPresetRow({
        name: "Repeaters",
        hold_s: 7,
        holds_s: null,
        reps: 6,
        sets: 3,
        target_kg: 10,
      }),
    ).toEqual({
      name: "Repeaters",
      hold_s: 7,
      reps: 6,
      sets: 3,
      target_kg: 10,
    });
  });

  it("rejects varied holds with an actionable migration message", () => {
    expect(() =>
      legacyPresetRow({
        hold_s: 5,
        holds_s: [5, 10, 20],
      }),
    ).toThrow(VARIED_HOLDS_REQUIRE_MIGRATION);
  });
});
