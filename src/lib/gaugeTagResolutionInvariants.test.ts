import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard over issue #684's persist-boundary rule, in the same
/// spirit as `signOutInvariants.test.ts` / `nativeAuthInvariants.test.ts` and
/// for the same reason: the property that matters here lives in a call site
/// (ForceView), not in the pure module, so a unit test of the module cannot
/// pin it. The r684 review (round 1) found both headline behaviours broken at
/// exactly the level a structural pin exists to catch — F1 (an auto-seed
/// writing the raw field) and F4 (one of seven persist sites bypassing the
/// boundary).
///
/// Pins, each matched to a finding:
///
/// 1. **The display fallback never feeds a saved rep** (F1's second order).
///    A `NewTindeqRecording` builder reading `liveEffectiveTag`, `allTags`,
///    or the resolved `gaugeInputs.tag` would stamp `allTags[0]` on a saved
///    rep. The boundary only ever sees the raw `pendingTag`/`pendingSide`.
/// 2. **No auto-seed writes `pendingTag`** (F1 itself). The mount-time
///    recordings fetch used to copy the most-recorded tag into the raw field
///    via `setPendingTag`; the boundary reads that as an explicit selection,
///    so an untagged free hold got filed under an exercise the user never
///    picked. `setPendingTag` must be reachable only from the user's own
///    `onTag` handler.
/// 3. **Every persist site resolves through the shared boundary** (F4).
///    The last-used fallback must apply at ALL persist sites — including the
///    sign-out salvage of a free hold — or two saves of the same pull
///    disagree. The shared `resolveBoundaryLabel` must be the recording
///    builder's tag/side source everywhere, and the salvage context must
///    carry it (`resolveLabel`) because the generic salvage row lives in
///    useTindeq.ts, outside ForceView.
/// 4. **The boundary reads the last-used pair from a ref** (F3 / the repo's
///    closure-race rule). An async path reading a captured render value is
///    this repo's most-repeated defect class.
///
/// Deliberately a crude text scan: it cannot be satisfied by refactoring
/// around it, only by not doing the thing. Comments and strings are stripped
/// so a mention inside a doc comment cannot satisfy a check about code.

const SRC = join(import.meta.dirname, "..");
const FORCE_VIEW = join(SRC, "components", "ForceView.tsx");
const USE_TINDEQ = join(SRC, "hooks", "useTindeq.ts");

function tsFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return tsFiles(path);
    if (/\.test\.tsx?$/.test(entry)) return [];
    return /\.tsx?$/.test(entry) ? [path] : [];
  });
}

/// Strips `//` comments and `/* … */` blocks — these modules necessarily
/// *discuss* `allTags[0]` and `pendingTag` at length, and the point is which
/// code reads/writes them.
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

const forceView = code(FORCE_VIEW);
const useTindeq = code(USE_TINDEQ);

describe("#684 persist-boundary invariants", () => {
  it("finds the sources it is guarding", () => {
    expect(sources.length).toBeGreaterThan(50);
    expect(forceView.length).toBeGreaterThan(10_000);
    expect(useTindeq.length).toBeGreaterThan(1_000);
  });

  it("no recording is ever stamped with the display fallback — the boundary expression never references liveEffectiveTag/allTags, and no builder reads gaugeInputs.tag (#684 F1)", () => {
    // `gaugeInputs.tag` is `liveEffectiveTag` (the display fallback that
    // becomes `allTags[0]`); stamping a recording with it is the exact
    // "worse than not locking it at all" footgun. The identifiers themselves
    // legitimately appear in DISPLAY code (the `GaugeInputs.tag` field, the
    // TagSideEditor props), so the pin targets the recording field stamp
    // `tag: gaugeInputs.tag` and the boundary expression's inputs — never the
    // plain word `allTags` on a display-prop line.
    const offenders = sources.flatMap(({ path, code }) => {
      const lines = code.split("\n");
      const lineOffenders = lines.flatMap((line, i) => {
        // A recording (or its builder) reading the RESOLVED display tag.
        const resolvedStamp = /(?:tag|side):\s*gaugeInputs\.tag\b/.test(line);
        return resolvedStamp ? [`${path}:${i + 1}: ${line.trim()}`] : [];
      });
      // The boundary call sites are multi-line (house style), so a per-line
      // `[^)]*` can never see the realistic regression — someone adding
      // `tag: liveEffectiveTag` INSIDE the object. Scan the whole file for a
      // boundary call whose argument block mentions the display fallback
      // (NEW-5: `[^)]` crosses newlines, unlike a per-line split).
      const boundaryDisplay = /resolveBoundary(?:Tag|Label)\s*\([^)]*?(?:liveEffectiveTag|allTags)[^)]*?\)/.test(
        code,
      );
      return boundaryDisplay ? [...lineOffenders, `${path}: boundary call references the display fallback`] : lineOffenders;
    });
    expect(offenders).toEqual([]);
  });

  it("no auto-seed writes pendingTag — the identifier appears exactly twice: the state declaration and the user's onTag handler (#684 F1)", () => {
    // F1: the mount-time recordings fetch used to copy the most-recorded tag
    // into `pendingTag` via `setPendingTag`, and the boundary read that as an
    // explicit selection. After the fix the ONLY writes are the `useState("")`
    // declaration and `handlePendingTag`'s body, which is what the
    // TagSideEditor's `onTag` calls — a real user pick. Any third occurrence
    // is an auto-seed and fails here.
    const occurrences = forceView.split("\n").map((line, i) => ({ line, i }))
      .filter(({ line }) => /setPendingTag\b/.test(line));
    expect(occurrences).toHaveLength(2);
    expect(occurrences[0]!.line).toMatch(/useState\s*\(\s*""\s*\)/);
    expect(occurrences[1]!.line).toMatch(/setPendingTag\s*\(\s*t\s*\)/);
  });

  it("every recording builder resolves through the shared boundary — tag at all persist sites, side only where the user chooses it for a free hold (#684 F4 / NEW-2)", () => {
    // The persist sites (r684 F4's enumeration + NEW-2's split): guided
    // per-rep hold, adaptive/hands-free run, reverse-action set, the free-hold
    // stop (including its recovery branch), reverse-action salvage, and the
    // sensorless manual attempt — plus the salvage context resolver that
    // carries the boundary into useTindeq.ts's generic sign-out row.
    //
    // NEW-2: the TAG falls back to the remembered pair at every site (that is
    // F4's design), but the remembered SIDE applies ONLY at the free-hold
    // sites — the free-hold stop, its recovery, and the generic sign-out
    // salvage row — where the user actually chooses a side for the hold. The
    // protocol sites keep the raw protocol side (`seg.side ?? pendingSide`,
    // `hold.side || snapshot.side`, `snapshot.side`) because a remembered side
    // must not stamp a rep whose zone/target were computed all-sides (a stale
    // side is indistinguishable from a real measurement and feeds per-side
    // curve fits — the exact hazard ForceView's own comment at :1302-1309
    // names). So: `resolveBoundaryLabel` (full pair) is used by the free-hold
    // sites + the salvage resolver; `resolveBoundaryTag` (tag only) by the
    // protocol sites.
    const fullBoundaryCalls = [...forceView.matchAll(/resolveBoundaryLabel\s*\(/g)];
    const tagBoundaryCalls = [...forceView.matchAll(/resolveBoundaryTag\s*\(/g)];
    // Free-hold stop (both branches: normal + recovery) — the only places a
    // full tag+side pair resolves, plus the sign-out salvage resolver
    // (`resolveLabel: resolveBoundaryLabel`, asserted below).
    expect(fullBoundaryCalls.length).toBeGreaterThanOrEqual(2);
    // The protocol persist sites (guided per-rep, adaptive, reverse live,
    // reverse salvage, manual) + the cadence-run Start — at least 6.
    expect(tagBoundaryCalls.length).toBeGreaterThanOrEqual(6);
    expect(forceView).toMatch(/resolveLabel:\s*resolveBoundaryLabel/);
    // The salvage row actually calls the resolver, with an explicit no-owner
    // fallback whose raw "" fields are what the resolver would produce anyway.
    expect(useTindeq).toMatch(/ctx\.resolveLabel\s*\?\.\s*\(/);
    // And no recording ever carries the resolved display tag (see the first
    // pin) — this complements it by pinning the boundary reads the RAW fields.
    expect(forceView).toMatch(
      /resolveBoundaryTag\(\s*gaugeInputs\.pendingTag/,
    );
  });

  it("the boundary reads the last-used pair from a ref at persist time — never a captured render value (#684 F3 / repo closure-race rule)", () => {
    // The repo's most-repeated defect class: a guard reading captured state
    // in an async path. `resolveBoundaryLabel` must read
    // `lastUsedGaugeLabelRef.current`, and the remember path must mirror the
    // ref synchronously on the same write as the state, so the two never
    // drift.
    expect(forceView).toMatch(
      /resolveRecordingGaugeLabel\(explicit,\s*lastUsedGaugeLabelRef\.current\)/,
    );
    expect(forceView).toMatch(/lastUsedGaugeLabelRef\.current\s*=\s*merged/);
  });
});
