#!/usr/bin/env python3
"""Exercise the `docs-check` classifier from native-swift.yml (#944).

The shell under test is EXTRACTED from the workflow file, so this harness
cannot drift from the shipped step. Each leg runs it in a throwaway git repo
whose diff is built from real repository paths, with the same environment
GitHub provides, and prints the `native=` output it published plus the raw
exit status.

Usage: python3 classify-harness.py <base-sha-before-944>
"""

import os
import re
import subprocess
import sys
import tempfile

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
WORKFLOW = os.path.join(REPO, ".github", "workflows", "native-swift.yml")

# Diffs built out of real repository paths.
DOCS_ONLY = [
    "README.md",
    "docs/testing.md",
    "docs/evidence/issue-944/hashes.txt",
    ".report-1.md",
    "justfile",
    "scripts/check-docs-stale-commands.sh",
]
MIXED = ["docs/testing.md", "native/SendmeterNative/Sources/App/AppModel.swift"]
NATIVE_ONLY = ["native/SendmeterNative/project.yml"]
WORKFLOW_ONLY = [".github/workflows/native-swift.yml"]
EMPTY = []


def classify_step():
    with open(WORKFLOW, encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    for step in doc["jobs"]["docs-check"]["steps"]:
        if step.get("id") == "classify":
            return step["run"]
    raise SystemExit("no classify step in docs-check")


def run(cmd, cwd, **kwargs):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, **kwargs)


def leg(name, shell, docs_paths, native_paths, event, base_kind):
    """base_kind: 'flat' (base == first commit), 'zero', 'bogus', 'none'."""
    with tempfile.TemporaryDirectory() as tmp:
        run(["git", "init", "-q"], tmp)
        run(["git", "config", "user.email", "lane@example.invalid"], tmp)
        run(["git", "config", "user.name", "lane"], tmp)

        def write(paths, marker):
            for path in paths:
                full = os.path.join(tmp, path)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "w", encoding="utf-8") as handle:
                    handle.write(marker + " " + path + "\n")

        write(["README.md"], "base")
        run(["git", "add", "-A"], tmp)
        run(["git", "commit", "-q", "-m", "base"], tmp)
        base_sha = run(["git", "rev-parse", "HEAD"], tmp).stdout.strip()

        if docs_paths or native_paths:
            write(docs_paths, "head-doc")
            write(native_paths, "head-native")
            run(["git", "add", "-A"], tmp)
            run(["git", "commit", "-q", "-m", "head"], tmp)

        output = os.path.join(tmp, "gh-output")
        env = dict(os.environ)
        env.pop("GITHUB_OUTPUT", None)
        env["GITHUB_OUTPUT"] = output
        env["EVENT_NAME"] = event
        env["PR_BASE_SHA"] = {
            "flat": base_sha,
            "zero": "0" * 40,
            "bogus": "deadbeef" * 5,
            "none": "",
        }[base_kind]
        env["PUSH_BEFORE_SHA"] = env["PR_BASE_SHA"]

        proc = subprocess.run(
            ["bash", "-c", shell], cwd=tmp, capture_output=True, text=True, env=env
        )
        published = ""
        if os.path.exists(output):
            with open(output, encoding="utf-8") as handle:
                published = handle.read().strip()
        native = dict(
            line.split("=", 1) for line in published.splitlines() if "=" in line
        ).get("native")
        print(
            "LEG %-28s exit=%d %-22s %s"
            % (name, proc.returncode, published or "(no output)", proc.stdout.strip())
        )
        return proc.returncode, native


def drift_check(base_sha):
    """Every path #944 added to the filters must classify as docs-only."""
    shell = classify_step()
    match = re.search(r"docs_surface='([^']+)'", shell)
    if not match:
        raise SystemExit("no docs_surface regex in the classify step")
    regex = re.compile(match.group(1))

    base = yaml.safe_load(
        subprocess.run(
            ["git", "show", "%s:.github/workflows/native-swift.yml" % base_sha],
            cwd=REPO,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    base_on = base.get(True) or base.get("on")
    head = yaml.safe_load(open(WORKFLOW, encoding="utf-8"))
    head_on = head.get(True) or head.get("on")
    added = [
        path
        for path in head_on["pull_request"]["paths"]
        if path not in base_on["pull_request"]["paths"]
    ]
    failures = 0
    for path in added:
        sample = path.replace("**", "evidence/x.log.gz").replace("*", "1")
        if not regex.match(sample):
            print("DRIFT %-32s sample %-32s NOT docs-only" % (path, sample))
            failures += 1
    print(
        "DRIFT-CHECK added-by-944=%d all-classify-docs-only=%s"
        % (len(added), failures == 0)
    )
    return failures


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    base_sha = sys.argv[1]
    shell = classify_step()

    results = [
        # name, docs paths, native paths, event, base kind, expected native
        ("pr_docs_only", DOCS_ONLY, EMPTY, "pull_request", "flat", "false"),
        ("pr_docs_plus_native", MIXED, EMPTY, "pull_request", "flat", "true"),
        ("pr_native_only", EMPTY, NATIVE_ONLY, "pull_request", "flat", "true"),
        ("pr_workflow_only", EMPTY, WORKFLOW_ONLY, "pull_request", "flat", "true"),
        ("pr_empty_diff", EMPTY, EMPTY, "pull_request", "flat", "true"),
        ("pr_unresolvable_base", EMPTY, NATIVE_ONLY, "pull_request", "bogus", "true"),
        ("dispatch", EMPTY, NATIVE_ONLY, "workflow_dispatch", "none", "true"),
        ("push_docs_only", DOCS_ONLY, EMPTY, "push", "flat", "false"),
        ("push_zero_before", EMPTY, NATIVE_ONLY, "push", "zero", "true"),
    ]

    failures = 0
    for name, docs, native, event, base_kind, expected in results:
        code, published = leg(name, shell, docs, native, event, base_kind)
        ok = code == 0 and published == expected
        if not ok:
            failures += 1
            print("  ^^ MISMATCH: expected native=%s" % expected)
    failures += drift_check(base_sha)
    print("HARNESS failures=%d legs=%d" % (failures, len(results)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
