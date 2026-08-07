import { readFileSync } from "node:fs";
import { join } from "node:path";
import ts from "typescript";
import { describe, expect, it } from "vitest";

/// Structural guard for #487 (F2) / review finding 3: a `NewTindeqRecording`
/// built without `recordedAt` silently falls back to the DB's
/// `recorded_at default now()` at WHATEVER MOMENT it finally gets inserted —
/// correct for a same-tick live save, wrong for anything that can be
/// delayed. Two routes delay it in production: `drainQueue` (an offline
/// recording drained hours later) and ForceView's #264 in-memory Retry
/// banner (`retryUnqueued`, which re-calls `insertRecording` on the SAME
/// object, possibly hours after capture). The first review pass of this fix
/// covered only `drainQueue` and missed `retryUnqueued` — a delayed-insert
/// path in the same file that wasn't checked — because the fix stamped the
/// field in the queue plumbing instead of at the object's construction.
///
/// The correct fix stamps `recordedAt` on every `NewTindeqRecording` at the
/// moment it's built, so the SAME object carries the right timestamp down
/// every route to `insertRecording`, however many times it's retried. This
/// test pins that structurally — a crude AST scan, deliberately, so it can't
/// be satisfied by refactoring around it, only by actually stamping the
/// field. It mirrors `nativeAuthInvariants.test.ts` / `signOutInvariants.test.ts`'s
/// "grep the source, not the runtime behavior" pattern for a property CI's
/// type-checker cannot enforce (recordedAt is optional on the type, by
/// design, since only the caller — not `insertRecording` — knows the real
/// capture moment).
///
/// What counts as "a real recording construction site": an object literal
/// with `id`, `samples` AND `durationMs` as DIRECT properties (not via a
/// spread — e.g. `buildReverseActionSetRecording`'s `...input.base` carries
/// `tag`/`groupId` that way, so those aren't usable as the anchor). All
/// three together are unique to the seven sites this list was built from —
/// `useTindeq.ts`'s `StoppedRecording` (an intermediate summary, not an
/// insert payload) has `samples` + `durationMs` but no `id`, so it does NOT
/// match and does NOT need `recordedAt`.
const SCANNED = [
  "src/components/ForceView.tsx",
  "src/lib/reverseAction.ts",
  "src/lib/cadenceOnlyRun.ts",
  "src/hooks/useTindeq.ts",
];

const REPO = join(import.meta.dirname, "..", "..");

function directPropertyNames(node: ts.ObjectLiteralExpression): string[] {
  return node.properties
    .map((p) => (p.name && ts.isIdentifier(p.name) ? p.name.text : undefined))
    .filter((n): n is string => n !== undefined);
}

interface RecordingLiteral {
  line: number;
  hasRecordedAt: boolean;
}

function findRecordingLiterals(path: string, code: string): RecordingLiteral[] {
  const source = ts.createSourceFile(path, code, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const found: RecordingLiteral[] = [];
  function visit(node: ts.Node) {
    if (ts.isObjectLiteralExpression(node)) {
      const names = directPropertyNames(node);
      if (names.includes("id") && names.includes("samples") && names.includes("durationMs")) {
        const { line } = source.getLineAndCharacterOfPosition(node.getStart());
        found.push({ line: line + 1, hasRecordedAt: names.includes("recordedAt") });
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  return found;
}

describe("every NewTindeqRecording construction site stamps recordedAt (#487, F2)", () => {
  const byFile = SCANNED.map((rel) => ({
    rel,
    literals: findRecordingLiterals(rel, readFileSync(join(REPO, rel), "utf8")),
  }));

  it("finds the construction sites it's supposed to be guarding", () => {
    // A path typo, a renamed field, or the scanner failing to match anything
    // would turn every assertion below into a vacuous pass — the exact
    // failure mode `nativeAuthInvariants.test.ts` guards against too. Seven
    // is the current real count (four in ForceView.tsx, one each in
    // reverseAction.ts/cadenceOnlyRun.ts/useTindeq.ts) — a new one is fine
    // and expected to raise this number, never to drop it.
    const total = byFile.reduce((sum, f) => sum + f.literals.length, 0);
    expect(total).toBeGreaterThanOrEqual(7);
  });

  for (const { rel } of byFile) {
    it(`${rel} — no unstamped recording literal`, () => {
      const { literals } = byFile.find((f) => f.rel === rel)!;
      const offenders = literals.filter((l) => !l.hasRecordedAt).map((l) => `${rel}:${l.line}`);
      expect(offenders).toEqual([]);
    });
  }
});
