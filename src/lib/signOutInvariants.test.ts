import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard over #273's sign-out policy, in the same spirit as
/// `nativeAuthInvariants.test.ts` and for the same reason: the rule that
/// matters here is about which code paths EXIST, and a rule nothing checks is
/// a comment.
///
/// Two properties, both of which cost the user's training data if they rot:
///
/// 1. **Queued recordings are deleted from exactly one place**, and that place
///    (`discardQueueOnUserSignOut`) first checks the user asked to sign out. A
///    forced or revoked sign-out — #265, which really happened — must never
///    reach it. A second caller of `clearRecordingQueue` would be a second
///    chance to get that check wrong, so there is not allowed to be one.
/// 2. **There is one sign-out implementation.** The two call sites used to
///    hold a copy each of `markUserSignOut()` + `supabase.auth.signOut()`;
///    that pair has just grown a destructive third step, and a third copy is
///    how the paths drift apart later.
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
/// *discuss* signing out and clearing the queue at length, and the point is
/// which code does it.
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

describe("#273 sign-out invariants", () => {
  it("finds the source tree it is scanning", () => {
    // A scan that silently matched nothing would pass every assertion below.
    expect(sources.length).toBeGreaterThan(50);
    expect(sources.map((s) => s.path)).toContain("lib/signOut.ts");
  });

  it("deletes queued recordings from exactly one place", () => {
    expect(callers(/\bclearRecordingQueue\s*\(/)).toEqual([
      // The definition …
      "lib/recordingQueue.ts",
      // … and the one caller, which checks the user's sign-out marker first.
      "lib/signOut.ts",
    ]);
  });

  it("keeps the marker check in front of that one caller", () => {
    const signOut = sources.find((s) => s.path === "lib/signOut.ts")?.code ?? "";
    // Not a proof of ordering — `signOut.test.ts` drives the real refusal —
    // but it fails loudly if the guard is deleted outright.
    expect(signOut).toMatch(/isUserSignOutPending/);
  });

  it("has one sign-out implementation", () => {
    expect(callers(/supabase\.auth\.signOut\s*\(/)).toEqual(["lib/signOut.ts"]);
    // The identifier, not a call: signOut.ts holds it as an injectable
    // default rather than calling it inline, and either shape counts.
    expect(callers(/\bmarkUserSignOut\b/)).toEqual([
      "lib/authDiagnostics.ts", // the definition
      "lib/signOut.ts",
    ]);
  });

  // #492 F1 (review): the discard path used to accept `userId: string |
  // null`, with `null` meaning "wipe every account's queue" — a real,
  // demonstrated race (two independent `getSession()` reads disagreeing
  // across a token rotation) could produce that `null` with no error and no
  // warning. Requiring a non-null `string` closes it at the type level, but
  // a type can be WIDENED back by a future edit with nothing else noticing —
  // pinned here the same crude, refactor-proof way as #1/#2 above.
  it("requires a non-null userId on the discard path — no caller can wipe unscoped", () => {
    const recordingQueue = sources.find((s) => s.path === "lib/recordingQueue.ts")?.code ?? "";
    const signOut = sources.find((s) => s.path === "lib/signOut.ts")?.code ?? "";
    expect(recordingQueue).toMatch(
      /export async function clearRecordingQueue\(\s*userId:\s*string,/,
    );
    expect(signOut).toMatch(
      /export async function discardQueueOnUserSignOut\(\s*userId:\s*string,/,
    );
  });
});
