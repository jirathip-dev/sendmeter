#!/usr/bin/env python3
"""#1030 — after vs approved #1028 pixel comparison (palette surfaces).

Phone: samples the tab canvas (2 % in, 15 % down) and the first hero card
(centre, 23.5 % down) on every after capture that has an approved twin, and
requires each channel within 3. Watch: the share of pixels differing by > 8
(the live clock differs by construction).

Usage (repo root):
  git archive fc1d8ada design-output/1028/screens | tar -x -C <dir>
  python3 docs/evidence/issue-1030/tools/compare-approved.py <dir>/design-output/1028/screens
Exit 1 if any phone sample differs.
"""
import os
import sys

from PIL import Image, ImageChops

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
AFTER = os.path.join(ROOT, "docs", "evidence", "issue-1030", "screens", "after")
APPROVED = os.path.join(sys.argv[1], "after")

failures = 0
for device in ("17pro", "se"):
    for name in sorted(os.listdir(os.path.join(AFTER, device))):
        twin = os.path.join(APPROVED, device, name)
        if not os.path.exists(twin):
            continue
        ours = Image.open(os.path.join(AFTER, device, name)).convert("RGB")
        theirs = Image.open(twin).convert("RGB").resize(ours.size)
        w, h = ours.size
        cells = []
        for label, (x, y) in (("canvas", (int(w * 0.02), int(h * 0.15))), ("heroCard", (int(w * 0.5), int(h * 0.235)))):
            a, b = ours.getpixel((x, y)), theirs.getpixel((x, y))
            same = max(abs(i - j) for i, j in zip(a, b)) <= 3
            failures += 0 if same else 1
            cells.append(f"{label} {'=' if same else 'DIFF'} {a} vs {b}")
        print(f"{device} {name}: " + " | ".join(cells))

for name in sorted(os.listdir(os.path.join(AFTER, "watch"))):
    twin = os.path.join(APPROVED, "watch", name)
    if not os.path.exists(twin):
        print(f"watch {name}: no approved capture")
        continue
    ours = Image.open(os.path.join(AFTER, "watch", name)).convert("RGB")
    theirs = Image.open(twin).convert("RGB").resize(ours.size)
    mask = ImageChops.difference(ours, theirs).convert("L").point(lambda v: 255 if v > 8 else 0)
    share = mask.histogram()[255] / (ours.size[0] * ours.size[1])
    print(f"watch {name}: {share:.1%} of pixels differ by > 8 (bbox {mask.getbbox()})")

print(f"phone sample mismatches: {failures}")
sys.exit(1 if failures else 0)
