#!/usr/bin/env bash
set -euo pipefail

# Bounded stale-command smoke check for the current contributor entrypoints
# (issue #931, follow-up to the #857 native-only cut).
#
# Read-only by construction: it reads tracked docs, the justfile, and the file
# tree. It never executes a documented command, never installs anything, and
# never talks to a network or a service.
#
# Checks:
#   1. AGENTS.md still resolves to CLAUDE.md (the guidance is one file; a
#      copied AGENTS.md would silently drift).
#   2. Retired web/Capacitor command names in a CURRENT entrypoint file fail
#      the check, with file:line and the pattern label.
#   3. Files that document the removal on purpose are in the explicit
#      historical allowlist below; their hits are reported, never failed.
#   4. Positive validation: backticked `just <recipe>`, `.github/workflows/…`,
#      `scripts/…` and `docs/…` references in the current files must exist.
#
# npm/npx mentions are exempt when the same line also names mcp — the mcp
# package keeps its own package-local npm commands; only root npm was retired.
#
# Exit status: 0 clean, 1 violation (details printed), 2 usage/setup problem.
#
# To allow a retired name on purpose: add the file to HISTORICAL_FILES with a
# reason (preferred for a document that records the removal), or, if the
# mention is genuinely current-guidance context, rephrase it to avoid the
# retired token.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

python3 - "$repo_root" <<'PY'
import os
import re
import sys

root = sys.argv[1]

# --- current contributor entrypoints: must stay clean -------------------
CURRENT_FILES = [
    "README.md",
    "CLAUDE.md",
    "docs/testing.md",
    "docs/security.md",
    "docs/mcp-e2e-verification.md",
    "docs/app-review-notes.md",
    "docs/native-touch-latency-ab.md",
]

# --- explicit historical allowlist: reported, never failed --------------
# path, reason
HISTORICAL_FILES = [
    (
        "docs/architecture/857-removal-inventory.md",
        "the #857 removal inventory — names every retired surface on purpose",
    ),
    (
        "docs/app-store-checklist.md",
        "Capacitor-era sections are banner-marked superseded; the screenshot "
        "lane section is banner-marked historical",
    ),
    (
        "docs/error-monitoring.md",
        "documents the retired web error-monitoring layer; banner-marked",
    ),
    (
        "docs/parity-gauntlet-brief.md",
        "historical gauntlet brief (completed batch); banner-marked",
    ),
    (
        "docs/ci/dependabot-fanout.md",
        "records the retired CI/deploy surface",
    ),
    (
        "docs/dependency-security.md",
        "records the retired root lockfile/Capacitor graph",
    ),
    (
        "FINDINGS-663.md",
        "dated findings record (pre-#857)",
    ),
    (
        "PERF-671.md",
        "dated measurement record (pre-#857)",
    ),
    (
        "RELEASE_NOTES.md",
        "changelog — historical entries legitimately name retired surfaces",
    ),
]

# label, pattern, mcp_scoped (True = skip when the line also says mcp)
RETIRED = [
    (
        "root npm script",
        r"\bnpm run (?:dev|dev:local|build|typecheck|lint|sync|sync:local|test|"
        r"test:coverage|db:[a-z-]+|migration:[a-z-]+)\b",
        True,
    ),
    ("root npm test", r"\bnpm test\b", True),
    ("root npm ci", r"\bnpm ci\b", True),
    ("root npm install", r"\bnpm install\b", True),
    ("Capacitor CLI", r"\bnpx cap\b", False),
    ("Capacitor sync", r"\bcap sync\b", False),
    ("generated Capacitor SPM", r"\bCapApp-SPM\b", False),
    ("retired Capacitor config", r"\bcapacitor\.config\.ts\b", False),
    ("retired App project", r"\bios/App/App\.xcodeproj\b", False),
    ("retired web bundle", r"\bios/App/App/public\b", False),
    ("retired App scheme", r"scheme [`'\"]?App\b", False),
    ("retired web config", r"\bvite\.config\.ts\b", False),
    ("retired web build", r"\bvite build\b", False),
    ("retired web dev server", r"\bvite dev\b", False),
    ("retired web test runner", r"\bvitest\b", False),
    ("retired web deploy config", r"\bvercel\.json\b", False),
    ("retired web deploy command", r"\bvercel dev\b", False),
    ("retired deploy workflow", r"(?<![-\w])deploy-web\.yml\b", False),
    ("retired Capacitor TestFlight workflow", r"(?<![-\w])testflight\.yml\b", False),
    ("retired web quality workflow", r"(?<![-\w])ci\.yml\b", False),
    (
        "retired React tree",
        r"\bsrc/(?:lib|hooks|components|types\.ts|constants\.ts|index\.css)\b",
        False,
    ),
    (
        "retired Capacitor plugin package",
        r"\bnative-plugins/sendlog-(?:health|auth-bridge|live-activity|passkey)"
        r"(?![\w-])",
        False,
    ),
    ("retired Capacitor beta lane", r"\bfastlane beta\b", False),
]


def read(path):
    with open(os.path.join(root, path), encoding="utf-8") as handle:
        return handle.read().splitlines()


def scan(path, text_lines, results):
    for lineno, line in enumerate(text_lines, start=1):
        lowered = line.lower()
        for label, pattern, mcp_scoped in RETIRED:
            if mcp_scoped and "mcp" in lowered:
                continue
            if re.search(pattern, line):
                results.append((path, lineno, label, line.strip()))


violations = []
historical_hits = {}
checked = 0

for path in CURRENT_FILES:
    if not os.path.isfile(os.path.join(root, path)):
        violations.append((path, 0, "current entrypoint is missing", path))
        continue
    checked += 1
    hits = []
    scan(path, read(path), hits)
    violations.extend(hits)

for path, reason in HISTORICAL_FILES:
    if not os.path.isfile(os.path.join(root, path)):
        violations.append((path, 0, "historical allowlist entry is missing", path))
        continue
    hits = []
    scan(path, read(path), hits)
    historical_hits[path] = (reason, len(hits))

# --- positive validation over the current files -------------------------
recipe_names = set()
with open(os.path.join(root, "justfile"), encoding="utf-8") as handle:
    for line in handle:
        match = re.match(r"([a-z][a-z0-9-]*):", line)
        if match:
            recipe_names.add(match.group(1))

positive_checks = [
    (
        "recipe",
        re.compile(r"`just ([a-z][a-z0-9-]*)`"),
        lambda name: name in recipe_names,
        lambda name: "no such recipe in justfile: just %s" % name,
    ),
    (
        "workflow",
        re.compile(r"\.github/workflows/([A-Za-z0-9._-]+\.ya?ml)"),
        lambda name: os.path.isfile(os.path.join(root, ".github", "workflows", name)),
        lambda name: "no such workflow file: .github/workflows/%s" % name,
    ),
    (
        "script",
        re.compile(r"(?<![\w/])scripts/([A-Za-z0-9._-]+)"),
        lambda name: os.path.isfile(os.path.join(root, "scripts", name)),
        lambda name: "no such script: scripts/%s" % name,
    ),
    (
        "doc",
        re.compile(r"docs/([A-Za-z0-9._/-]+\.md)"),
        lambda name: os.path.isfile(os.path.join(root, "docs", name)),
        lambda name: "no such doc: docs/%s" % name,
    ),
]

RECIPE_IN_FENCE = re.compile(r"^\s*just ([a-z][a-z0-9-]*)\b")


def fenced_code(lines):
    """Yield lines inside ``` fences (a documented command is a command)."""
    inside = False
    for line in lines:
        if line.lstrip().startswith("```"):
            inside = not inside
            continue
        if inside:
            yield line


for path in CURRENT_FILES:
    if not os.path.isfile(os.path.join(root, path)):
        continue
    lines = read(path)
    text = "\n".join(lines)
    for kind, pattern, exists, message in positive_checks:
        for name in sorted(set(pattern.findall(text))):
            if not exists(name):
                violations.append((path, 0, "%s reference" % kind, message(name)))
    for name in sorted(
        {name for line in fenced_code(lines) for name in RECIPE_IN_FENCE.findall(line)}
    ):
        if name not in recipe_names:
            violations.append(
                (path, 0, "recipe reference", "no such recipe in justfile: just %s" % name)
            )

# --- AGENTS.md must stay a symlink to CLAUDE.md -------------------------
agents = os.path.join(root, "AGENTS.md")
claude = os.path.join(root, "CLAUDE.md")
if not os.path.exists(agents):
    violations.append(("AGENTS.md", 0, "guidance entrypoint missing", "AGENTS.md"))
elif os.path.realpath(agents) != os.path.realpath(claude):
    violations.append(
        (
            "AGENTS.md",
            0,
            "guidance symlink replaced",
            "AGENTS.md must resolve to CLAUDE.md, not be a separate copy",
        )
    )

# --- report -------------------------------------------------------------
print("docs-stale-commands: scanned %d current entrypoints, %d historical files, "
      "%d retired-command patterns"
      % (checked, len(HISTORICAL_FILES), len(RETIRED)))
for path, (reason, count) in historical_hits.items():
    print("  historical (allowlisted): %s — %s (%d retired-name hit%s)"
          % (path, reason, count, "" if count == 1 else "s"))

if violations:
    print("")
    for path, lineno, label, detail in violations:
        location = "%s:%d" % (path, lineno) if lineno else path
        print("FAIL: %s: %s: %s" % (location, label, detail))
    print("")
    print("docs-stale-commands: FAILED with %d violation(s)" % len(violations))
    sys.exit(1)

print("docs-stale-commands: OK — current entrypoints name no retired command, "
      "and every referenced recipe/workflow/script/doc exists")
PY
