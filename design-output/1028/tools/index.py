#!/usr/bin/env python3
"""#1028 — rewrite the README artifact index from what is on disk.

Replaces the block between <!-- index:start --> and <!-- index:end --> in
design-output/1028/README.md. Deterministic (sorted, no timestamps).
`--check` exits 1 if the committed index is stale.
Usage (repo root): python3 design-output/1028/tools/index.py [--check]
"""
import os
import re
import sys

BASE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
README = os.path.join(BASE, "README.md")
START, END = "<!-- index:start -->", "<!-- index:end -->"

sys.path.insert(0, os.path.dirname(__file__))
from sheets import ORDER, STATE_TITLES  # noqa: E402  (one source of state names)

DEVICES = [("17pro", "iPhone 17 Pro"), ("se", "iPhone SE (3rd gen)"), ("watch", "Apple Watch")]


def proposal_range():
    """'P1–Pn' read from proposals.md, so the index never drifts from it."""
    with open(os.path.join(BASE, "proposals.md"), encoding="utf-8") as fh:
        text = fh.read()
    numbers = [int(n) for n in re.findall(r"^\| P(\d+) \|", text, flags=re.M)]
    return f"P1–P{max(numbers)}" if numbers else "proposals"

def rel(*parts):
    return "/".join(parts)


def exists(*parts):
    return os.path.exists(os.path.join(BASE, *parts))


def build():
    out = []
    out.append("### Before/after sheets (one per state; before dark · after dark · before light · after light)")
    out.append("")
    for device, title in DEVICES:
        rows = [s for s in ORDER if exists("sheets", f"{device}-{s}.png")]
        if not rows:
            continue
        out.append(f"**{title}**")
        out.append("")
        for scheme in ("dark", "light"):
            if exists("sheets", f"{device}-overview-{scheme}.png"):
                out.append(f"- [Overview, every after state, {scheme}]({rel('sheets', f'{device}-overview-{scheme}.png')})")
        for state in rows:
            out.append(f"- [{STATE_TITLES[state]}]({rel('sheets', f'{device}-{state}.png')})")
        out.append("")
    if exists("sheets", "mascot-in-app.png"):
        out.append("**Mascots in the app** (approved vs refined candidate, real size)")
        out.append("")
        out.append(f"- [{rel('sheets', 'mascot-in-app.png')}]({rel('sheets', 'mascot-in-app.png')})")
        out.append("")
    out.append("### Raw screenshots")
    out.append("")
    for version in ("before", "after"):
        for device, title in DEVICES:
            folder = os.path.join(BASE, "screens", version, device)
            if os.path.isdir(folder):
                n = len([f for f in os.listdir(folder) if f.endswith(".png")])
                out.append(f"- `{rel('screens', version, device)}/`: {n} PNGs ({title}, {version})")
    out.append("")
    out.append("### Specs, tools, gates")
    out.append("")
    for path, what in [
        ("tokens.md", "token table: every token, dark/light hex, where it is used, WCAG ratio for every text pair"),
        ("proposals.md", f"{proposal_range()} for the owner to accept or reject, and what was deliberately left out"),
        ("mascots/mascot-sheet.png", "mascot before/after, dark and light, props shown"),
        ("mascots/out/force-1028-160.svg", "refined Force mascot (candidate)"),
        ("mascots/out/workout-1028-160.svg", "refined Workout mascot (candidate)"),
        ("mascots/generate.py", "deterministic mascot refinement"),
        ("mascots/verify.py", "mascot gates: masters byte-pinned, determinism, pose overlap, holes, local drift, prop clearance"),
        ("tools/capture-phone.sh", "phone captures (status bar pinned, app proven frontmost)"),
        ("tools/capture-watch.sh", "Watch captures"),
        ("tools/stage-screens.sh", "raw captures to repo screenshots (50%, stripped, byte-stable); runs check-shots.py first"),
        ("tools/check-shots.py", "fail-closed check that every phone capture shows the app, not the splash or home screen"),
        ("tools/sheets.py", "before/after sheets"),
        ("tools/tokens.sh", "compiles the shipped palette and writes or checks tokens.md"),
        ("tools/f5-gate.sh", "F5 UI test GREEN, plus a mutation that must turn it RED"),
        ("tools/index.py", "this index"),
    ]:
        if exists(*path.split("/")):
            out.append(f"- [`{path}`]({path}): {what}")
    return "\n".join(out).rstrip() + "\n"


def main():
    text = open(README, encoding="utf-8").read()
    if START not in text or END not in text:
        sys.exit("README is missing the index markers")
    head, rest = text.split(START, 1)
    _, tail = rest.split(END, 1)
    new = f"{head}{START}\n{build()}{END}{tail}"
    if "--check" in sys.argv:
        if new != text:
            sys.exit("README index is stale: run tools/index.py")
        print("README index is current")
        return
    with open(README, "w", encoding="utf-8") as f:
        f.write(new)
    print("wrote README index")


if __name__ == "__main__":
    main()
