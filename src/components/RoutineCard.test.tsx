// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ROUTINE_PREPARE_S, expandRoutine, routineDurationS } from "../lib/routine";
import { clearRoutineRun, saveRoutineRun } from "../lib/routineRun";
import type { RoutinePreset } from "../types";

/// Behavioral pin for #493 F-D (the #295/#296 closure-capture defect class).
///
/// RoutineCard's mount effect (`[]` deps) can log a session from its `.then` —
/// an interrupted-but-actually-completed run resolved by resolveRoutineResume.
/// That path once read the `currentPhase` PROP, captured at mount by the
/// effect's closure. It happened to be safe only because App.tsx renders the
/// tabs behind a loading gate until the phase is known — an invariant that
/// lives two files away and that nothing pinned, which is exactly how #295 and
/// #296 shipped. The fix reads `currentPhaseRef.current` instead.
///
/// This test renders the real component, holds the presets fetch open past a
/// phase change, and asserts the logged session carries the phase that was
/// CURRENT when the log happened — not the one captured at mount. Reverting
/// logRoutine to the captured prop fails it with a wrong VALUE
/// (phase: "capacity" instead of "power"), not a missing symbol.

const h = vi.hoisted(() => {
  let resolvePresets: ((presets: unknown) => void) | null = null;
  return {
    insertSession: vi.fn((fields: Record<string, unknown>) =>
      Promise.resolve({ id: "session-1", ...fields }),
    ),
    fetchRoutinePresets: vi.fn(
      () =>
        new Promise((res) => {
          resolvePresets = res;
        }),
    ),
    resolvePresets: (presets: unknown) => {
      if (!resolvePresets) throw new Error("fetchRoutinePresets was never called");
      resolvePresets(presets);
    },
  };
});

vi.mock("../lib/repo", () => ({
  fetchRoutinePresets: h.fetchRoutinePresets,
  insertSession: h.insertSession,
  deleteSession: vi.fn(),
  deleteRoutinePreset: vi.fn(),
  insertRoutinePreset: vi.fn(),
  updateRoutinePreset: vi.fn(),
}));

// Keeps the test off Capacitor imports (useWakeLock) — never rendered here
// anyway: a resolved "completed" outcome logs without re-opening the timer.
vi.mock("./RoutineFullscreen", () => ({ default: () => null }));

vi.mock("../lib/monitoring", () => ({
  captureHandledOperationalFailure: vi.fn(),
}));

import RoutineCard from "./RoutineCard";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// Node's own experimental global `localStorage` shadows jsdom's here and is
// non-functional without `--localstorage-file` (setItem throws, which
// routineRun.ts deliberately swallows — persistence is best-effort). Replace
// it with a working in-memory store so saveRoutineRun/loadRoutineRun work.
const backing = new Map<string, string>();
vi.stubGlobal("localStorage", {
  getItem: (k: string) => backing.get(k) ?? null,
  setItem: (k: string, v: string) => void backing.set(k, String(v)),
  removeItem: (k: string) => void backing.delete(k),
  clear: () => backing.clear(),
});

describe("RoutineCard mount-time auto-log (#493 F-D)", () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    vi.clearAllMocks();
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(async () => {
    await act(async () => {
      root.unmount();
    });
    container.remove();
    clearRoutineRun();
  });

  it("logs a resumed-completed run with the phase current at log time, not the mount-captured one", async () => {
    // A persisted run whose heartbeat confirmed it all the way to the end,
    // read back much later: resolveRoutineResume classifies it "completed"
    // and the mount effect's `.then` logs it — the exact async path where a
    // closure-captured prop goes stale.
    const preset: RoutinePreset = {
      id: "p1",
      name: "Test routine",
      steps: [{ label: "Hang", s: 300 }],
    };
    const totalS = routineDurationS(expandRoutine(preset.steps, { prepareS: ROUTINE_PREPARE_S }));
    const startedMs = Date.now() - 60 * 60_000;
    saveRoutineRun({
      presetId: preset.id,
      startedMs,
      skippedS: 0,
      pausedAtMs: null,
      pausedTotalMs: 0,
      lastSeenMs: startedMs + totalS * 1000,
    });

    // Mount while the phase is still "capacity" and the presets fetch is
    // held open…
    await act(async () => {
      root.render(<RoutineCard currentPhase="capacity" />);
    });
    expect(h.fetchRoutinePresets).toHaveBeenCalledTimes(1);
    expect(h.insertSession).not.toHaveBeenCalled();

    // …the phase changes before the fetch lands (in production: the phase
    // arriving/changing after RoutineCard mounted — the situation App.tsx's
    // loading gate happens to prevent today and nothing else guarantees)…
    await act(async () => {
      root.render(<RoutineCard currentPhase="power" />);
    });

    // …then the fetch resolves and the mount effect's `.then` logs the run.
    await act(async () => {
      h.resolvePresets([preset]);
    });

    expect(h.insertSession).toHaveBeenCalledTimes(1);
    const logged = h.insertSession.mock.calls[0]![0];
    // The pin: the ref reads the phase current at log time. A revert to the
    // mount-captured `currentPhase` prop logs "capacity" here.
    expect(logged.phase).toBe("power");
    // Sanity that this really was the resumed-completed auto-log path.
    expect(logged.type).toBe("routine");
    expect(logged.note).toContain("auto-logged");
    expect(logged.duration).toBe(Math.round(totalS / 60));
  });
});
