# #930 — DESIGN.md native contract + stale-reference check — evidence

Lane `impl-930` (docs-only, slice D01). Two artifacts:

- `DESIGN.md` — the native design contract that replaces the retired web spec.
- `scripts/check-design-contract.sh` — the document's own lightweight
  stale-reference check.

The logs here are the raw runs of that check. RED legs run against a scratch
APFS clone of the lane worktree (`cp -Rc` → `/tmp/impl-930-redgreen`, `.git`
removed) with one deliberate defect each; the GREEN legs run the identical
script — one in a pristine copy of the same tree, one in the lane worktree
itself. The check script is never run against a mutated real worktree.

| Log | Leg | Mutation / state | Raw exit |
|---|---|---|---|
| `design-contract-check-red-A.log.gz` | RED | cited path broken (`NativeForceCurveCard.swift` → `GhostCurveCard.swift`) | 1 |
| `design-contract-check-red-B.log.gz` | RED | line citation out of range (`DesignSystem.swift:139-99999`) | 1 |
| `design-contract-check-red-C.log.gz` | RED | symbol index points `StatusPill` at a file that does not contain it | 1 |
| `design-contract-check-red-D.log.gz` | RED | retired CSS recipe `.btn-primary` moved OUTSIDE the historical block | 1 |
| `design-contract-check-red-E.log.gz` | RED | retired path `src/index.css` resurrected in the tree | 1 |
| `design-contract-check-red-F.log.gz` | RED | historical end marker removed | 1 |
| `design-contract-check-green-copy.log.gz` | GREEN | pristine scratch copy of the same tree | 0 |
| `design-contract-check-green-real.log.gz` | GREEN | the lane worktree | 0 |

Observed failure lines (quoted from the logs above):

```
FAIL: DESIGN.md:252: cited path: GhostCurveCard.swift: no such file in the tree
FAIL: DESIGN.md:127: line citation out of range: DesignSystem.swift:99999 (file has 555 lines)
FAIL: DESIGN.md:382: symbol index: `StatusPill` no longer appears in native/SendmeterNative/Sources/App/ChartTheme.swift
FAIL: DESIGN.md:316: retired CSS recipe outside the historical block: For the record, the old action fill was `.btn-primary`.
FAIL: DESIGN.md:324: historical path is back in the tree: src/index.css (retired web stylesheet)
FAIL: DESIGN.md: historical block markers are missing, duplicated or out of order
```

Green run (both legs):

```
design-contract: DESIGN.md 417 lines, 158 cited paths resolved, 96 line citations in range, 41 symbols in the index, 4 historical absent-paths allowlisted
design-contract: OK — every cited path and symbol resolves, historical tokens stay inside the marked block
RAW_EXIT=0
```

The RED legs were produced by `/tmp/impl-930-redgreen-proof.sh` (lane-local
scratch driver, not committed); each mutation asserted its own match count
before editing, and each leg started from a fresh clone.

Scope note: this evidence covers reference *resolution* (paths, line ranges,
symbols, retired tokens). It does not re-verify that the prose matches product
behavior; those citations are for the reviewer to check, and the code pages
listed in the red logs are the raw check output only — no product code was run.
