// @vitest-environment jsdom
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act, createElement, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useWakeLock } from "./useWakeLock";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

/// Strips comments, same crude text-scan this repo already uses for wiring
/// invariants a purely-unit-tested lib module can't see (see
/// routineResumeInvariants.test.ts).
function code(relPath: string): string {
  return readFileSync(join(import.meta.dirname, relPath), "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

const source = code("useWakeLock.ts");

describe("useWakeLock.ts structural invariants (#533 review)", () => {
  it("finds the source file it is scanning", () => {
    // A path typo would silently match an empty/wrong string below.
    expect(source.length).toBeGreaterThan(500);
  });

  it("the web WebWakeLockCoordinator is built inside the effect, never hoisted to module scope", () => {
    // Unlike `nativeCoordinator` right above it, a WebWakeLockCoordinator's
    // cleanup() is terminal — it permanently blocks further acquire() calls
    // on that instance. Hoisting it the same way `nativeCoordinator` is
    // hoisted would brick the web wake lock for the rest of the session
    // after the first unmount (review round 1, finding 6).
    //
    // Checked by POSITION, not declaration syntax (review round 2, finding
    // 4: a `^const \w+ =` regex misses `let`, `export const`, and a
    // declaration split across lines) — every `new WebWakeLockCoordinator(`
    // call site must fall strictly inside the function body, and
    // specifically inside its first (web) `useEffect`, not before the
    // function starts or inside the second (native) effect.
    const fnStart = source.indexOf("export function useWakeLock");
    expect(fnStart).toBeGreaterThan(-1);
    const effectStart = source.indexOf("useEffect(() => {", fnStart);
    const effectEnd = source.indexOf("}, [active]);", effectStart);
    expect(effectStart).toBeGreaterThan(fnStart);
    expect(effectEnd).toBeGreaterThan(effectStart);

    const ctorSites = [...source.matchAll(/new WebWakeLockCoordinator\(/g)];
    expect(ctorSites.length).toBeGreaterThan(0);
    for (const site of ctorSites) {
      const index = site.index ?? -1;
      expect(index).toBeGreaterThan(fnStart);
      expect(index).toBeGreaterThan(effectStart);
      expect(index).toBeLessThan(effectEnd);
    }
  });

  it("the visibilitychange listener is removed before cleanup() runs", () => {
    const effectStart = source.indexOf("useEffect(() => {");
    const returnIdx = source.indexOf("return () => {", effectStart);
    const bodyEnd = source.indexOf("}, [active]);", returnIdx);
    expect(returnIdx).toBeGreaterThan(-1);
    expect(bodyEnd).toBeGreaterThan(returnIdx);
    const cleanupBody = source.slice(returnIdx, bodyEnd);

    const removeIdx = cleanupBody.indexOf("document.removeEventListener");
    const cleanupCallIdx = cleanupBody.indexOf("coordinator.cleanup()");
    expect(removeIdx).toBeGreaterThan(-1);
    expect(cleanupCallIdx).toBeGreaterThan(-1);
    // Ordering matters: cleanup() being terminal means any onVis firing
    // between the two calls must not be able to re-acquire on a coordinator
    // that's about to be discarded.
    expect(removeIdx).toBeLessThan(cleanupCallIdx);
  });
});

function fakeSentinel(label: string) {
  let listener: (() => void) | null = null;
  let releasedFlag = false;
  const release = vi.fn(async () => {
    releasedFlag = true;
    listener?.();
  });
  return {
    label,
    release,
    get released() {
      return releasedFlag;
    },
    addEventListener: (_type: string, l: () => void) => {
      listener = l;
    },
  };
}

async function flushMicrotasks() {
  for (let i = 0; i < 8; i++) {
    await Promise.resolve();
  }
}

describe("useWakeLock (web) behavior", () => {
  let container: HTMLDivElement;
  let root: Root;
  let requestMock: ReturnType<typeof vi.fn>;
  let originalWakeLock: PropertyDescriptor | undefined;

  function Probe({ active }: { active: boolean }) {
    useWakeLock(active);
    return null;
  }

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
    requestMock = vi.fn();
    originalWakeLock = Object.getOwnPropertyDescriptor(navigator, "wakeLock");
    Object.defineProperty(navigator, "wakeLock", {
      configurable: true,
      value: { request: requestMock },
    });
  });

  afterEach(async () => {
    await act(async () => {
      root.unmount();
      await flushMicrotasks();
    });
    container.remove();
    if (originalWakeLock) {
      Object.defineProperty(navigator, "wakeLock", originalWakeLock);
    } else {
      delete (navigator as unknown as Record<string, unknown>).wakeLock;
    }
    vi.restoreAllMocks();
  });

  // Review round 1, finding 5 (updated round 2, finding 2). StrictMode
  // synchronously mounts, cleans up, and remounts the effect within a
  // single commit — entirely before any microtask runs, so the first
  // coordinator's cleanup() lands before its request is even issued. Round
  // 2's fix makes that request never get issued at all (rather than issued
  // and immediately released), so only the second (never-cleaned-up)
  // coordinator's request goes out, and no sentinel is ever released for a
  // request that was never made.
  it("StrictMode's mount→cleanup→mount issues exactly one request — the first coordinator's cleanup pre-empts its own", async () => {
    const sentinels = [fakeSentinel("A"), fakeSentinel("B")];
    let i = 0;
    requestMock.mockImplementation(() => Promise.resolve(sentinels[i++]));

    await act(async () => {
      root.render(
        createElement(StrictMode, null, createElement(Probe, { active: true })),
      );
      await flushMicrotasks();
    });

    expect(requestMock).toHaveBeenCalledTimes(1);
    expect(sentinels[0]?.release).not.toHaveBeenCalled();
    expect(sentinels[1]?.release).not.toHaveBeenCalled();
  });

  // Review round 1, finding 6 (behavioral half of the structural pin above):
  // proves a plain (non-StrictMode) active→inactive→active cycle gets a
  // brand-new coordinator each time, so the old instance's terminal
  // cleanup() can never brick the next acquire — the exact failure mode
  // hoisting to module scope (like `nativeCoordinator`) would cause.
  it("toggling active off then on builds a fresh coordinator — the old one's cleanup never blocks the new one", async () => {
    const sentinels = [fakeSentinel("A"), fakeSentinel("B")];
    let i = 0;
    requestMock.mockImplementation(() => Promise.resolve(sentinels[i++]));

    await act(async () => {
      root.render(createElement(Probe, { active: true }));
      await flushMicrotasks();
    });
    expect(requestMock).toHaveBeenCalledTimes(1);
    expect(sentinels[0]?.released).toBe(false);

    await act(async () => {
      root.render(createElement(Probe, { active: false }));
      await flushMicrotasks();
    });
    expect(sentinels[0]?.release).toHaveBeenCalledTimes(1);

    await act(async () => {
      root.render(createElement(Probe, { active: true }));
      await flushMicrotasks();
    });
    expect(requestMock).toHaveBeenCalledTimes(2);
    expect(sentinels[1]?.release).not.toHaveBeenCalled();
  });
});
