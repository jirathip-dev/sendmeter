#!/usr/bin/env bash
set -euo pipefail

# Lightweight stale-reference check for DESIGN.md (issue #930, slice D01).
#
# Read-only by construction: it reads DESIGN.md and the file tree. It never
# executes a documented command, never installs anything, and never talks to a
# network or a service.
#
# It complements, and does not duplicate or replace,
# `scripts/check-docs-stale-commands.sh` (#931), which owns the retired-command
# name list for the other current entrypoints and whose CI wiring is #944's.
#
# Checks:
#   1. every repo path cited in DESIGN.md resolves to exactly one file in the
#      tree (repo-root-relative, or a unique path suffix), and every
#      `file:line[-line]` citation is inside that file's line count;
#   2. every row of DESIGN.md's `Symbol index` table still names a symbol that
#      appears in the file the row cites;
#   3. retired web/Capacitor design tokens appear ONLY between this document's
#      `design-contract:historical` markers.
#
# The historical block is a record, not guidance: the paths listed in
# HISTORICAL_ABSENT below are expected to be GONE, and the check fails if one
# comes back (an allowlist with reasons, not a blanket skip).
#
# Exit status: 0 clean, 1 violation (details printed), 2 usage/setup problem.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
doc="$repo_root/DESIGN.md"

[[ -f "$doc" ]] || { echo "check-design-contract: missing $doc" >&2; exit 2; }

python3 - "$repo_root" "$doc" <<'PY'
import os
import re
import sys

root, doc_path = sys.argv[1], sys.argv[2]

BEGIN = "<!-- design-contract:historical:begin -->"
END = "<!-- design-contract:historical:end -->"

# Retired paths cited in the historical block that must stay ABSENT.
HISTORICAL_ABSENT = {
    "src/index.css": "retired web stylesheet",
    "public/fonts/OFL.txt": "retired self-hosted web font",
    "capacitor.config.ts": "retired Capacitor host config",
    "ios/App/App/public": "retired web bundle path",
}

# Retired design tokens/commands: fail anywhere outside the historical block.
BANNED = [
    ("retired CSS custom property", r"--t-"),
    ("retired theme attribute", r"data-theme"),
    ("retired web stylesheet", r"src/index\.css"),
    ("retired web font", r"\bInter\b"),
    ("retired web font", r"\bDM Mono\b|\bSyne\b"),
    ("retired web font path", r"public/fonts"),
    ("retired CSS recipe", r"\.btn-(?:primary|secondary|danger|ghost)\b"),
    ("retired CSS recipe", r"\.(?:bottom-nav|account-fab|modal-sheet)\b"),
    ("retired ripple hook", r"\buseRipple\b|\.tap-ripple"),
    ("retired CSS feature", r"backdrop-filter|prefers-color-scheme|font-variant-numeric"),
    ("retired PWA identity", r"\btheme-color\b|grid-2-desktop"),
    ("retired Capacitor command", r"\bnpx cap\b|\bcap sync\b|\bCapApp-SPM\b"),
    ("retired web command", r"\bvite (?:build|dev)\b|\bnpm run (?:dev|build|sync)\b"),
]

with open(doc_path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()

# --- marker sanity -------------------------------------------------------
begins = [i for i, line in enumerate(lines) if line.strip() == BEGIN]
ends = [i for i, line in enumerate(lines) if line.strip() == END]
if len(begins) != 1 or len(ends) != 1 or begins[0] > ends[0]:
    print("FAIL: DESIGN.md: historical block markers are missing, duplicated or out of order")
    sys.exit(1)
history = range(begins[0], ends[0] + 1)

# --- file index ----------------------------------------------------------
SKIP_DIRS = {".git", ".build", "DerivedData", "node_modules", ".swiftpm", ".xcodeproj"}
tree = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.endswith(".xcodeproj")]
    for name in filenames:
        rel = os.path.relpath(os.path.join(dirpath, name), root)
        tree.append(rel.replace(os.sep, "/"))
tree_set = set(tree)

violations = []


def resolve(path):
    """Repo-root-relative path, or a unique path suffix. Returns (file, error)."""
    if path in tree_set:
        return path, None
    matches = [candidate for candidate in tree if candidate.endswith("/" + path)]
    if len(matches) == 1:
        return matches[0], None
    if not matches:
        return None, "no such file in the tree"
    return None, "ambiguous path suffix: %s" % ", ".join(sorted(matches)[:4])


CITE = re.compile(
    r"([A-Za-z0-9_@][A-Za-z0-9_@./-]*\.(?:swift|md|sh|ya?ml|json|plist|svg|png|css|txt|ts|tsx))"
    r"(?::(\d+)(?:-(\d+))?)?"
)

checked_paths = 0
checked_lines = 0

# --- retired paths cited in the historical block must stay ABSENT --------
for lineno, line in enumerate(lines, start=1):
    if (lineno - 1) not in history:
        continue
    for path, reason in HISTORICAL_ABSENT.items():
        if path in line and any(candidate == path or candidate.endswith("/" + path) for candidate in tree):
            violations.append(
                "DESIGN.md:%d: historical path is back in the tree: %s (%s)" % (lineno, path, reason)
            )

for lineno, line in enumerate(lines, start=1):
    in_history = (lineno - 1) in history
    for match in CITE.finditer(line):
        path, start, stop = match.group(1), match.group(2), match.group(3)
        if path.startswith(("http://", "https://")):
            continue
        resolved, error = resolve(path)
        if error:
            if in_history:
                # Historical citations may name removed files; only call them
                # out when they were expected to stay (allowlist is explicit).
                if path in HISTORICAL_ABSENT:
                    continue
                violations.append("DESIGN.md:%d: historical citation: %s: %s" % (lineno, path, error))
                continue
            violations.append("DESIGN.md:%d: cited path: %s: %s" % (lineno, path, error))
            continue
        checked_paths += 1
        if start and not in_history:
            last = int(stop or start)
            with open(os.path.join(root, resolved), encoding="utf-8", errors="replace") as handle:
                total = sum(1 for _ in handle)
            checked_lines += 1
            if last > total:
                violations.append(
                    "DESIGN.md:%d: line citation out of range: %s:%s (file has %d lines)"
                    % (lineno, path, stop or start, total)
                )

# --- symbol index --------------------------------------------------------
ROW = re.compile(r"^\|\s*`([A-Za-z_][A-Za-z0-9_]*)`\s*\|\s*`([^`]+)`\s*\|\s*$")
symbols = 0
for lineno, line in enumerate(lines, start=1):
    if (lineno - 1) in history:
        continue
    row = ROW.match(line)
    if not row:
        continue
    symbol, path = row.group(1), row.group(2)
    resolved, error = resolve(path)
    if error:
        violations.append("DESIGN.md:%d: symbol index source: %s: %s" % (lineno, path, error))
        continue
    with open(os.path.join(root, resolved), encoding="utf-8", errors="replace") as handle:
        body = handle.read()
    if symbol not in body:
        violations.append(
            "DESIGN.md:%d: symbol index: `%s` no longer appears in %s" % (lineno, symbol, resolved)
        )
        continue
    symbols += 1

if symbols < 10:
    violations.append(
        "DESIGN.md: symbol index table looks truncated (%d rows parsed; 10 is the floor)" % symbols
    )

# --- banned retired tokens ----------------------------------------------
for lineno, line in enumerate(lines, start=1):
    if (lineno - 1) in history:
        continue
    for label, pattern in BANNED:
        if re.search(pattern, line):
            violations.append(
                "DESIGN.md:%d: %s outside the historical block: %s" % (lineno, label, line.strip()[:100])
            )

# --- report --------------------------------------------------------------
print(
    "design-contract: DESIGN.md %d lines, %d cited paths resolved, %d line citations in range, "
    "%d symbols in the index, %d historical absent-paths allowlisted"
    % (len(lines), checked_paths, checked_lines, symbols, len(HISTORICAL_ABSENT))
)

if violations:
    print("")
    for item in violations:
        print("FAIL: %s" % item)
    print("")
    print("design-contract: FAILED with %d violation(s)" % len(violations))
    sys.exit(1)

print("design-contract: OK — every cited path and symbol resolves, historical tokens stay inside the marked block")
PY
