import { describe, expect, it } from "vitest";
import { restoreAt } from "./restoreAt";

describe("restoreAt (issue #166)", () => {
  it("inserts the item back at its original index", () => {
    const list = [{ id: "a" }, { id: "c" }];
    expect(restoreAt(list, { id: "b" }, 1)).toEqual([
      { id: "a" },
      { id: "b" },
      { id: "c" },
    ]);
  });

  it("inserts at the front when index is 0", () => {
    const list = [{ id: "b" }];
    expect(restoreAt(list, { id: "a" }, 0)).toEqual([{ id: "a" }, { id: "b" }]);
  });

  it("clamps an index past the end (list shrank in the meantime)", () => {
    const list = [{ id: "a" }];
    expect(restoreAt(list, { id: "z" }, 99)).toEqual([{ id: "a" }, { id: "z" }]);
  });

  it("is a no-op if an item with the same id is already present", () => {
    const list = [{ id: "a" }, { id: "b" }];
    expect(restoreAt(list, { id: "b" }, 0)).toEqual(list);
  });

  it("does not mutate the input list", () => {
    const list = [{ id: "a" }];
    const next = restoreAt(list, { id: "b" }, 1);
    expect(list).toEqual([{ id: "a" }]);
    expect(next).not.toBe(list);
  });
});
