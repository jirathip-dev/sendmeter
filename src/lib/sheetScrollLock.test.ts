// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  acquireSheetScrollLock,
  SHEET_SCROLL_LOCK_CLASS,
} from "./sheetScrollLock";

describe("acquireSheetScrollLock", () => {
  let releaseLocks: Array<() => void> = [];
  let previousBodyStyle = "";
  let previousDocumentStyle = "";
  let previousBodyClass = "";
  let previousDocumentClass = "";

  beforeEach(() => {
    releaseLocks = [];
    previousBodyStyle = document.body.style.cssText;
    previousDocumentStyle = document.documentElement.style.cssText;
    previousBodyClass = document.body.className;
    previousDocumentClass = document.documentElement.className;
  });

  afterEach(() => {
    for (const release of releaseLocks.reverse()) release();
    document.body.style.cssText = previousBodyStyle;
    document.documentElement.style.cssText = previousDocumentStyle;
    document.body.className = previousBodyClass;
    document.documentElement.className = previousDocumentClass;
    document.querySelectorAll(".content-area").forEach((root) => root.remove());
  });

  it("locks every app scroll root and restores its prior state and position", () => {
    document.body.style.cssText = "overflow: clip; color: red;";
    document.documentElement.style.cssText = "overflow: scroll;";

    const firstRoot = document.createElement("div");
    firstRoot.className = "content-area app-scroll-root";
    firstRoot.style.cssText = "overflow-y: auto; overflow-x: hidden; color: blue;";
    firstRoot.scrollTop = 37;
    firstRoot.scrollLeft = 4;
    const firstStyle = firstRoot.style.cssText;
    const firstClass = firstRoot.className;

    const secondRoot = document.createElement("div");
    secondRoot.className = "content-area secondary-scroll-root";
    secondRoot.style.cssText = "overflow: auto;";
    secondRoot.scrollTop = 19;
    const secondStyle = secondRoot.style.cssText;
    const secondClass = secondRoot.className;
    document.body.append(firstRoot, secondRoot);

    releaseLocks.push(acquireSheetScrollLock());

    expect(document.body.style.overflow).toBe("hidden");
    expect(document.documentElement.style.overflow).toBe("hidden");
    expect(firstRoot.classList.contains(SHEET_SCROLL_LOCK_CLASS)).toBe(true);
    expect(secondRoot.classList.contains(SHEET_SCROLL_LOCK_CLASS)).toBe(true);
    expect(firstRoot.style.overflow).toBe("hidden");
    expect(firstRoot.style.overscrollBehavior).toBe("none");
    expect(secondRoot.style.overflow).toBe("hidden");

    firstRoot.scrollTop = 999;
    firstRoot.dispatchEvent(new Event("scroll"));
    expect(firstRoot.scrollTop).toBe(37);

    releaseLocks[0]!();
    expect(document.body.style.cssText).toBe("overflow: clip; color: red;");
    expect(document.documentElement.style.cssText).toBe("overflow: scroll;");
    expect(firstRoot.style.cssText).toBe(firstStyle);
    expect(firstRoot.className).toBe(firstClass);
    expect(firstRoot.scrollTop).toBe(37);
    expect(firstRoot.scrollLeft).toBe(4);
    expect(secondRoot.style.cssText).toBe(secondStyle);
    expect(secondRoot.className).toBe(secondClass);
  });

  it("keeps the lock through nested acquisitions and restores only once", () => {
    const root = document.createElement("div");
    root.className = "content-area";
    root.style.overflowY = "auto";
    root.scrollTop = 52;
    document.body.append(root);
    const priorStyle = root.style.cssText;
    const priorClass = root.className;

    releaseLocks.push(acquireSheetScrollLock());
    releaseLocks.push(acquireSheetScrollLock());
    expect(root.classList.contains(SHEET_SCROLL_LOCK_CLASS)).toBe(true);

    releaseLocks[0]!();
    expect(document.body.style.overflow).toBe("hidden");
    expect(root.classList.contains(SHEET_SCROLL_LOCK_CLASS)).toBe(true);
    expect(root.style.overflow).toBe("hidden");

    releaseLocks[1]!();
    expect(document.body.style.overflow).toBe("");
    expect(root.style.cssText).toBe(priorStyle);
    expect(root.className).toBe(priorClass);
    expect(root.scrollTop).toBe(52);

    // React effect cleanup can be called defensively more than once.
    releaseLocks[1]!();
    expect(root.style.cssText).toBe(priorStyle);
  });

  it("does not remove a lock class that was present before opening", () => {
    const root = document.createElement("div");
    root.className = `content-area ${SHEET_SCROLL_LOCK_CLASS}`;
    document.body.append(root);
    const priorClass = root.className;

    releaseLocks.push(acquireSheetScrollLock());
    releaseLocks[0]!();

    expect(root.className).toBe(priorClass);
  });
});
