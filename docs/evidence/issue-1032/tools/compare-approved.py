#!/usr/bin/env python3
"""#1032 (from #1031): after vs approved #1028, a whole-frame pixel diff per state.

For every after capture with an approved twin (same device, state and
scheme), reports the share of pixels whose channels differ by more than 16
and the bounding box of those pixels in points (1/2 of the stored 1.5x px,
i.e. the staged 50% copy of a 3x capture). The status-bar clock and the
recent-recording timestamps differ by construction (capture date), so a
non-zero share is expected; the bounding boxes say WHERE.

Usage (repo root):
  git archive fc1d8ada design-output/1028/screens | tar -x -C <dir>
  python3 docs/evidence/issue-1032/tools/compare-approved.py <dir>/design-output/1028/screens
Report only: exit 0 unless an input is unreadable.
"""
import os
import sys

from PIL import Image, ImageChops

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
AFTER = os.path.join(ROOT, "docs", "evidence", "issue-1032", "screens", "after")
APPROVED = os.path.join(sys.argv[1], "after")

for device in ("17pro", "se"):
    scale = 1.5 if device == "17pro" else 1.0
    for name in sorted(os.listdir(os.path.join(AFTER, device))):
        twin = os.path.join(APPROVED, device, name)
        if not os.path.exists(twin):
            print(f"{device} {name}: no approved twin")
            continue
        ours = Image.open(os.path.join(AFTER, device, name)).convert("RGB")
        theirs = Image.open(twin).convert("RGB")
        if theirs.size != ours.size:
            theirs = theirs.resize(ours.size)
        mask = ImageChops.difference(ours, theirs).convert("L").point(lambda v: 255 if v > 16 else 0)
        share = mask.histogram()[255] / (ours.size[0] * ours.size[1])
        box = mask.getbbox()
        where = "none" if box is None else "x %d-%d y %d-%d pt" % tuple(round(v / scale) for v in (box[0], box[2], box[1], box[3]))
        # Excluding the home-indicator strip (the bottom 16 pt): simulator
        # chrome, present in one run and absent in another.
        h = ours.size[1]
        body = mask.crop((0, 0, ours.size[0], h - round(16 * scale)))
        body_share = body.histogram()[255] / (ours.size[0] * ours.size[1])
        body_box = body.getbbox()
        body_where = "none" if body_box is None else "x %d-%d y %d-%d pt" % tuple(round(v / scale) for v in (body_box[0], body_box[2], body_box[1], body_box[3]))
        print(f"{device} {name}: {share:.2%} differ by > 16 ({where}); above the home indicator {body_share:.2%} ({body_where})")
