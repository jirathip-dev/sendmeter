import { describe, expect, it, vi } from "vitest";
import {
  isMissingPresetHoldsColumn,
  legacyPresetRow,
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
