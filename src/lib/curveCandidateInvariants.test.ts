import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard: ForceView must build its curve input through
/// `curveCandidateRecordings`, not a bare `recordings.filter(...)` (#325).
///
/// Why this file exists rather than a normal unit test: the behavioural test in
/// `force-curve.test.ts` calls `curveCandidateRecordings` directly, so it proves
/// the FILTER excludes prehab — but nothing in it observes ForceView. Restore
/// the old inline `recordings.filter(r => r.tag === … && side …)` at the call
/// site and every behavioural test still passes, while the regression this
/// guard exists to prevent ships green.
///
/// That regression is slow and silent, which is what earns the oddness here:
/// a Prehab hold is submaximal by construction, but `pickCurveRecordings` keeps
/// the longest efforts "regardless of load". A daily flat 30s sub-CF hold
/// becomes the only long-end fit point, the regression flattens, and next
/// session's target is derived from the corrupted CF — ratcheting down every
/// session, through every %-of-CF prescription and the CF banked for the
/// watch's RPE prediction (#280). Nobody notices for weeks.
///
/// Deliberately a crude text scan, in the style of
/// `nativeAuthInvariants.test.ts`: it cannot be satisfied by refactoring around
/// it, only by not doing the thing. Per this repo's own rule — a rule nothing
/// checks is a comment.

const FORCE_VIEW = join(
  import.meta.dirname,
  "..",
  "components",
  "ForceView.tsx",
);

describe("curve candidacy is routed through the shared filter (#325)", () => {
  const src = readFileSync(FORCE_VIEW, "utf8");

  it("ForceView builds curveRecordings via curveCandidateRecordings", () => {
    expect(src).toMatch(/curveRecordings\s*=\s*curveCandidateRecordings\(/);
  });

  it("imports it from the shared lib rather than redefining it locally", () => {
    expect(src).toMatch(
      /import\s*\{[^}]*\bcurveCandidateRecordings\b[^}]*\}\s*from\s*["']\.\.\/lib\/zoneHistory["']/,
    );
    expect(src).not.toMatch(/function\s+curveCandidateRecordings\b/);
  });

  it("does not reintroduce an inline recordings.filter for curve input", () => {
    // The old shape: `const curveRecordings = recordings.filter(...)`.
    expect(src).not.toMatch(/curveRecordings\s*=\s*recordings\.filter\(/);
  });
});
