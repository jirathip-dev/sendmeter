import { describe, it, expect } from "vitest";
import { mergeUnqueuedAfterRetry } from "./unqueuedRetry";

function rec(id: string) {
  return { id };
}

describe("mergeUnqueuedAfterRetry (#462)", () => {
  it("keeps a recording appended after the retry snapshot was taken", () => {
    const pending = [rec("a"), rec("b")];
    const appendedDuringRetry = rec("c");
    const current = [...pending, appendedDuringRetry];
    const stillLost: typeof pending = [];

    expect(mergeUnqueuedAfterRetry(current, pending, stillLost)).toEqual([
      appendedDuringRetry,
    ]);
  });

  it("re-adds items that failed retry again, without dropping a concurrently-appended one", () => {
    const pending = [rec("a"), rec("b")];
    const appendedDuringRetry = rec("c");
    const current = [...pending, appendedDuringRetry];
    const stillLost = [rec("a")];

    expect(mergeUnqueuedAfterRetry(current, pending, stillLost)).toEqual([
      appendedDuringRetry,
      rec("a"),
    ]);
  });

  it("does not duplicate an id that is both still present and still lost", () => {
    const pending = [rec("a")];
    const current = [rec("a")];
    const stillLost = [rec("a")];

    expect(mergeUnqueuedAfterRetry(current, pending, stillLost)).toEqual([rec("a")]);
  });

  it("re-adds a stillLost item even if it's already absent from current", () => {
    // The commit is idempotent: an item that failed retry again belongs back
    // in the list regardless of what else happened to `current` meanwhile.
    const pending = [rec("a")];
    const current: ReturnType<typeof rec>[] = [];
    const stillLost = [rec("a")];

    expect(mergeUnqueuedAfterRetry(current, pending, stillLost)).toEqual([rec("a")]);
  });

  it("an empty retry (nothing pending) leaves current untouched", () => {
    const current = [rec("x"), rec("y")];
    expect(mergeUnqueuedAfterRetry(current, [], [])).toEqual(current);
  });
});
