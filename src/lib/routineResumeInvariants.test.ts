import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard over #483's resume/finish fix, in the same spirit as
/// `nativeAuthInvariants.test.ts` / `signOutInvariants.test.ts`.
///
/// The #483 review's most serious finding (F2) was that every prior test for
/// this fix exercised `src/lib/routineRun.ts` in isolation — so the *entire*
/// production wiring (`RoutineCard.tsx`'s mount decision, `RoutineFullscreen`
/// 's finish/heartbeat/gap handling) could be reverted to `staging` and every
/// test, including the new ones, stayed green. Pure-logic tests of the lib
/// functions cannot catch that by construction: they call the lib directly
/// and never look at whether a component actually calls it.
///
/// This file closes that gap with the same crude, deliberate text-scan this
/// repo already uses for exactly this problem: it cannot be satisfied by
/// refactoring around it, only by the production files actually calling the
/// shared decision functions the way this fix requires. Verified (see
/// HANDOFF.md) to fail for a real reason — not a missing symbol — when
/// `RoutineCard.tsx`/`RoutineFullscreen.tsx` are reverted to `staging` while
/// `src/lib/routineRun.ts` keeps this fix's implementation.

const ROOT = join(import.meta.dirname, "..");

/// Strips `//` comments and `/* … */` blocks — these modules discuss the
/// fix at length in comments, and the point is which code actually runs.
function code(relPath: string): string {
  return readFileSync(join(ROOT, relPath), "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

const card = code("components/RoutineCard.tsx");
const fullscreen = code("components/RoutineFullscreen.tsx");

describe("#483 routine resume/finish invariants", () => {
  it("finds the two source files it is scanning", () => {
    // A path typo would silently match an empty/wrong string below.
    expect(card.length).toBeGreaterThan(2000);
    expect(fullscreen.length).toBeGreaterThan(2000);
  });

  it("RoutineCard's mount-time resume decision is delegated to resolveRoutineResume, not re-derived inline", () => {
    // The pre-#483 bug was exactly a re-derived inline formula
    // (`resumeRun && list.some((p) => p.id === resumeRun.presetId)`) with no
    // elapsed/total check at all. Guard against that shape reappearing, and
    // require the shared function to actually be called with the persisted
    // run, not just imported.
    expect(card).toMatch(/resolveRoutineResume\(\s*resumeRun\s*,/);
    expect(card).not.toMatch(/resumeRun\s*&&\s*list\.some/);
  });

  it("RoutineCard handles every resolveRoutineResume outcome kind, not just resume/none", () => {
    // A revert that dropped the completed/partial/discarded branches (i.e.
    // reproduced the reviewed fix's own F1 silent-discard bug) fails here.
    expect(card).toMatch(/case\s+"resume"/);
    expect(card).toMatch(/case\s+"none"/);
    expect(card).toMatch(/case\s+"completed"/);
    expect(card).toMatch(/case\s+"partial"/);
    expect(card).toMatch(/case\s+"discarded"/);
  });

  it("a discarded outcome is always surfaced with a visible toast, never swallowed silently (#483 review F1)", () => {
    const i = card.indexOf('case "discarded"');
    expect(i).toBeGreaterThan(-1);
    // The discarded branch's own body (up to the next `case`/closing brace)
    // must call the toast — this is the one behavior the review named as
    // strictly worse than either alternative if it regresses.
    const body = card.slice(i, i + 300);
    expect(body).toMatch(/toast\(/);
  });

  /// #483 re-review N5: "never discard silently" was asserted as an
  /// invariant but the `{kind:"none"}` case (a persisted run whose preset was
  /// deleted — a real, previously-confirmed run, not "there was nothing
  /// here") still cleared with no toast. The rule now has to hold there too.
  it("the none-outcome branch also toasts when it actually discards a run (#483 re-review N5)", () => {
    const i = card.indexOf('case "none"');
    expect(i).toBeGreaterThan(-1);
    const body = card.slice(i, i + 400);
    expect(body).toMatch(/toast\(/);
  });

  it("RoutineFullscreen gates its finish handling on a heartbeat/gap check, not unconditional onFinish (#483 review F3)", () => {
    // Pre-review-round `RoutineFullscreen` fired onFinish unconditionally
    // whenever `done` flipped true, with no notion of whether anyone was
    // actually present — including across a suspended (not remounted)
    // WebView, which never re-runs RoutineCard's mount-time check at all.
    expect(fullscreen).toMatch(/STALE_GAP_S/);
    expect(fullscreen).toMatch(/onStaleFinish\(/);
    expect(fullscreen).toMatch(/classifyElapsed\(/);
  });

  /// #483 re-review N2: `onStaleFinish` being an optional prop meant deleting
  /// the whole call site out of RoutineCard — F3's entire suspended-WebView
  /// remedy — left `tsc`/tests fully green: `finishedRef` is already set and
  /// `clearRoutineRun()` already ran by the time the (missing) callback would
  /// fire, so the record is destroyed with nothing logged and no toast. Pin
  /// the call site itself, not just that RoutineFullscreen offers the prop.
  it("RoutineCard actually wires onStaleFinish, not just RoutineFullscreen offering it (#483 re-review N2)", () => {
    expect(card).toMatch(/onStaleFinish=\{/);
  });

  it("onStaleFinish is a required prop, not optional (#483 re-review N2)", () => {
    // TypeScript can't catch a missing *optional* prop at all; requiring it
    // at least turns an omission into a type error at the call site.
    expect(fullscreen).toMatch(/onStaleFinish:\s*\(outcome/);
    expect(fullscreen).not.toMatch(/onStaleFinish\?:/);
  });

  /// #483 re-review N1: a guided routine is exactly the workflow where the
  /// user puts the phone down — without a wake lock, an ordinary iOS
  /// auto-lock suspends the WebView mid-routine, freezing the lastSeenMs
  /// heartbeat at the lock instant, so even a routine the user actually
  /// completed logs as a 1-2 minute partial or nothing at all. ForceView
  /// already holds a wake lock for its own fullscreen timer for the same
  /// reason.
  it("RoutineFullscreen holds a wake lock while mounted (#483 re-review N1)", () => {
    expect(fullscreen).toMatch(/useWakeLock\(/);
  });

  it("the completed-routine duration excludes Skip's fast-forwarded time (#483 review F4)", () => {
    // `elapsed` (used for segment position / the done flag) legitimately
    // includes skippedS so Skip can reach "done" sooner; the LOGGED duration
    // must not inherit that credit. Guard against the exact regression: an
    // onFinish call built directly from `elapsed`.
    expect(fullscreen).not.toMatch(/loggedMinutes\(\s*elapsed\s*,/);
    expect(fullscreen).toMatch(/loggedMinutes\(\s*realElapsed\s*,/);
  });

  it("the early-exit duration also excludes Skip's fast-forwarded time", () => {
    expect(fullscreen).not.toMatch(/onExitEarly\(\s*elapsed\s*\)/);
    expect(fullscreen).toMatch(/onExitEarly\(\s*realElapsed\s*\)/);
  });

  it("RoutineCard's preset-total display expands with the same prepareS as the live timer (#483 review F7)", () => {
    expect(card).toMatch(/expandRoutine\(\s*steps\s*,\s*\{\s*prepareS:\s*ROUTINE_PREPARE_S\s*\}\s*\)/);
  });
});
