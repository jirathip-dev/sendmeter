#!/usr/bin/env python3
"""Mutation probe helper for lane impl-923 (sendmeter).

mutate   <file> <literal_old> <literal_new> <backup_dir> <id> <evidence_dir>
    - asserts the literal occurs EXACTLY once (silent no-match burned cycles
      in earlier lanes), snapshots the original bytes to <backup_dir>/<id>.orig,
      writes the mutation, writes a unified diff to <evidence_dir>/probe-<id>.diff.

restore  <file> <backup_dir> <id> <repo> <evidence_dir>
    - restores the file from the snapshot with cp, then proves byte-identity
      with `git hash-object <file>` == `git rev-parse HEAD:<relpath>` when the
      file is tracked; writes the receipt to
      <evidence_dir>/probe-<id>-restored.txt.
"""
import difflib
import pathlib
import subprocess
import sys


def mutate(file_path, old, new, backup_dir, probe_id, evidence_dir):
    p = pathlib.Path(file_path)
    text = p.read_text()
    count = text.count(old)
    assert count == 1, f"literal occurs {count} times in {file_path}, expected exactly 1"
    backup = pathlib.Path(backup_dir) / f"{probe_id}.orig"
    backup.parent.mkdir(parents=True, exist_ok=True)
    backup.write_bytes(p.read_bytes())
    mutated = text.replace(old, new, 1)
    p.write_text(mutated)
    ev = pathlib.Path(evidence_dir)
    ev.mkdir(parents=True, exist_ok=True)
    diff = difflib.unified_diff(
        text.splitlines(keepends=True),
        mutated.splitlines(keepends=True),
        fromfile=f"a/{p.name}",
        tofile=f"b/{p.name}",
    )
    (ev / f"probe-{probe_id}.diff").write_text("".join(diff))
    print(f"MUTATED {file_path} -> backup {backup} diff {ev}/probe-{probe_id}.diff")


def restore(file_path, backup_dir, probe_id, repo, evidence_dir):
    p = pathlib.Path(file_path)
    backup = pathlib.Path(backup_dir) / f"{probe_id}.orig"
    p.write_bytes(backup.read_bytes())
    rel = str(p.resolve().relative_to(pathlib.Path(repo).resolve()))
    local = subprocess.run(
        ["git", "hash-object", file_path], cwd=repo, capture_output=True, text=True
    ).stdout.strip()
    head = subprocess.run(
        ["git", "rev-parse", f"HEAD:{rel}"], cwd=repo, capture_output=True, text=True
    ).stdout.strip()
    clean = subprocess.run(
        ["git", "status", "--porcelain", "--", rel], cwd=repo, capture_output=True, text=True
    ).stdout.strip()
    receipt = (
        f"file: {rel}\n"
        f"local git hash-object: {local}\n"
        f"HEAD:{rel}      : {head}\n"
        f"byte-identical to committed blob: {local == head}\n"
        f"git status --porcelain  : '{clean}'\n"
    )
    ev = pathlib.Path(evidence_dir)
    (ev / f"probe-{probe_id}-restored.txt").write_text(receipt)
    print(receipt)
    if local != head:
        sys.exit(1)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "mutate":
        mutate(*sys.argv[2:8])
    elif cmd == "restore":
        restore(*sys.argv[2:7])
    else:
        sys.exit(f"unknown command {cmd}")
