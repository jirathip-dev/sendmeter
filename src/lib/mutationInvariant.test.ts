import { describe, expect, it } from "vitest";
import {
  ZeroRowMutationError,
  isZeroRowMutationError,
  unwrapOneMutation,
} from "./mutationInvariant";

describe("unwrapOneMutation", () => {
  it("returns the single affected row", () => {
    expect(unwrapOneMutation({ data: { id: "row-1" }, error: null })).toEqual({
      id: "row-1",
    });
  });

  it("preserves a real database failure for local classification", () => {
    const error = { code: "42501", message: "permission denied" };
    expect(() => unwrapOneMutation({ data: null, error })).toThrow(error);
  });

  it("turns a successful zero-row response into a controlled invariant", () => {
    let caught: unknown;
    try {
      unwrapOneMutation({ data: null, error: null });
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(ZeroRowMutationError);
    expect(isZeroRowMutationError(caught)).toBe(true);
    expect(caught).toMatchObject({ affectedRows: 0 });
  });
});
