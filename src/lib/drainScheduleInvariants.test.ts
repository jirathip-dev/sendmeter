import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// R2-F2 (#484 re-review) — structural guard over "is the queue-drain
/// schedule actually wired into the app", in the same spirit and shape as
/// `signOutInvariants.test.ts` and `nativeAuthInvariants.test.ts`: "the rule
/// that matters here is about which code paths EXIST, and a rule nothing
/// checks is a comment."
///
/// The logic worth getting wrong (does a foreground/online signal actually
/// cause a drain, does `isOnline()` gate it, does cleanup remove every
/// listener) IS pure-logic tested, directly, in `drainSchedule.test.ts` —
/// against `scheduleQueueDrain` and the real `browserDrainHandles` adapter,
/// not a hand-rolled fake reimplementing it. What NOTHING checked before this
/// file is the one line connecting that tested logic to the app: does
/// `App.tsx` actually call `scheduleQueueDrain(runDrain,
/// browserDrainHandles(...))`, or does it (as it did before #484, and as a
/// careless future edit could make it again) just call
/// `drainPendingRecordingsQueue` once on mount and never again. Reverting
/// App.tsx's drain effect to that pre-#484 shape while leaving every other
/// file at HEAD passes the entire rest of the suite (1328/1328) — this file
/// is what catches that specific regression.
///
/// Deliberately a crude text scan: it cannot be satisfied by refactoring
/// around it, only by not doing the thing.

const SRC = join(import.meta.dirname, "..");

function tsFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return tsFiles(path);
    if (/\.test\.tsx?$/.test(entry)) return [];
    return /\.tsx?$/.test(entry) ? [path] : [];
  });
}

/// Strips `//` comments and `/* … */` blocks — these modules necessarily
/// *discuss* the drain schedule at length, and the point is which code does
/// the actual calling.
function code(path: string): string {
  return readFileSync(path, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

const sources = tsFiles(SRC).map((path) => ({
  path: path.slice(SRC.length + 1).replaceAll("\\", "/"),
  code: code(path),
}));

function callers(pattern: RegExp): string[] {
  return sources.filter((s) => pattern.test(s.code)).map((s) => s.path);
}

describe("#484 R2-F2 drain-schedule invariants", () => {
  it("finds the source tree it is scanning", () => {
    // A scan that silently matched nothing would pass every assertion below.
    expect(sources.length).toBeGreaterThan(50);
    expect(sources.map((s) => s.path)).toContain("App.tsx");
  });

  it("calls scheduleQueueDrain from exactly its definition and App.tsx", () => {
    // Includes the defining line itself (`export function scheduleQueueDrain(`
    // also matches) — same shape `signOutInvariants.test.ts` uses for
    // `clearRecordingQueue`. If App.tsx stops calling this — reverting to a
    // bare one-shot `drainPendingRecordingsQueue` call, the exact pre-#484
    // defect — this list shrinks to one entry and the test fails.
    expect(callers(/\bscheduleQueueDrain\s*\(/).sort()).toEqual(
      ["lib/drainSchedule.ts", "App.tsx"].sort(),
    );
  });

  it("calls browserDrainHandles from exactly its definition and App.tsx", () => {
    // The real DOM/Capacitor adapter (not a hand-rolled fake) has to be the
    // thing actually wired up, not merely defined and unit-tested in
    // isolation.
    expect(callers(/\bbrowserDrainHandles\s*\(/).sort()).toEqual(
      ["lib/drainSchedule.ts", "App.tsx"].sort(),
    );
  });

  it("wires scheduleQueueDrain and browserDrainHandles together in the SAME file", () => {
    // Passing the two checks above independently would still be satisfied by
    // App.tsx calling one and some other file calling the other — neither
    // proves they're connected. This is the one assertion that actually
    // pins "App.tsx runs scheduleQueueDrain against the real adapter".
    const app = sources.find((s) => s.path === "App.tsx")?.code ?? "";
    expect(app).toMatch(/\bscheduleQueueDrain\s*\(/);
    expect(app).toMatch(/\bbrowserDrainHandles\s*\(/);
  });

  it("keeps drainPendingRecordingsQueue's callers to the known set", () => {
    // Definition + the deliberate direct callers: the pre-sign-out drain
    // (signOut.ts, which needs a synchronous deadline the schedule doesn't
    // offer), the scheduled effect (App.tsx), and History's explicit
    // "Retry now" action for a stuck upload. A stray new direct caller would
    // be bypassing the schedule/foreground/backoff wiring this file exists
    // to pin — and if App.tsx's own call disappeared, this list would shrink
    // too.
    //
    // No trailing `(` in the pattern: signOut.ts holds the function as an
    // injectable default (`deps.drain ?? drainPendingRecordingsQueue`)
    // rather than calling it inline — the same "identifier, not a call"
    // shape `signOutInvariants.test.ts` already treats as counting for
    // `markUserSignOut`.
    expect(callers(/\bdrainPendingRecordingsQueue\b/).sort()).toEqual(
      [
        "App.tsx",
        "components/HistoryView.tsx",
        "lib/recordingQueue.ts",
        "lib/signOut.ts",
      ].sort(),
    );
  });
});
