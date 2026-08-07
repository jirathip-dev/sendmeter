import { readFileSync, readdirSync, statSync } from "node:fs";
import { extname, join } from "node:path";
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
/// three together are unique to the current seven sites — `useTindeq.ts`'s
/// `StoppedRecording` (an intermediate summary, not an insert payload) has
/// `samples` + `durationMs` but no `id`, so it does NOT match and does NOT
/// need `recordedAt`.
///
/// A first version of this test hardcoded the four files known to contain a
/// site at the time. That is the exact failure this test exists to catch,
/// wearing a costume: an eighth site arriving in a NEW file (the same way
/// `reverseAction.ts` and `cadenceOnlyRun.ts` themselves arrived) would pass
/// silently — the file list itself would need updating first, by the same
/// person who'd need to remember to stamp `recordedAt`. Walking all of `src`
/// removes that dependency: a new file is scanned automatically, with no
/// list to keep in sync. Test files are excluded — fixture helpers like
/// `recordingQueue.test.ts`'s `rec()` construct the identical `{id, samples,
/// durationMs}` shape as plain test data, not a real insert payload, and
/// have no reason to carry a capture timestamp.
const REPO = join(import.meta.dirname, "..", "..");
const SRC = join(REPO, "src");

function sourceFilesUnder(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return sourceFilesUnder(path);
    const ext = extname(path);
    if (ext !== ".ts" && ext !== ".tsx") return [];
    if (path.endsWith(".test.ts") || path.endsWith(".test.tsx")) return [];
    if (path.endsWith(".d.ts")) return [];
    return [path];
  });
}

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
  const kind = path.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const source = ts.createSourceFile(path, code, ts.ScriptTarget.Latest, true, kind);
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
  const files = sourceFilesUnder(SRC).map((abs) => abs.slice(REPO.length + 1));

  it("walked the source tree it's supposed to be guarding", () => {
    // Guards the walk itself, not just the match count below — a broken SRC
    // path or a `readdirSync` that silently returned nothing would otherwise
    // make every assertion in this file vacuously pass. This is the failure
    // mode a hardcoded file list quietly reintroduces for any file NOT on
    // the list (see the doc comment above): the fix is to make "scanned
    // nothing" loud here, not to trust a maintained list.
    expect(files.length).toBeGreaterThan(50);
    expect(files).toContain("src/lib/repo/tindeq.ts");
    expect(files).toContain("src/components/ForceView.tsx");
  });

  const byFile = files.map((rel) => ({
    rel,
    literals: findRecordingLiterals(rel, readFileSync(join(REPO, rel), "utf8")),
  }));

  it("finds the construction sites it's supposed to be guarding", () => {
    // Seven is the current real count (four in ForceView.tsx, one each in
    // reverseAction.ts/cadenceOnlyRun.ts/useTindeq.ts) — a new one is fine
    // and expected to raise this number, never to drop it.
    const total = byFile.reduce((sum, f) => sum + f.literals.length, 0);
    expect(total).toBeGreaterThanOrEqual(7);
  });

  it("has no unstamped recording literal anywhere under src", () => {
    // One aggregated assertion over the whole walk (not one `it()` per
    // SCANNED file, since there is no longer a fixed file list) — a new
    // construction site in ANY file, existing or brand new, shows up here.
    const offenders = byFile.flatMap(({ rel, literals }) =>
      literals.filter((l) => !l.hasRecordedAt).map((l) => `${rel}:${l.line}`),
    );
    expect(offenders).toEqual([]);
  });
});
