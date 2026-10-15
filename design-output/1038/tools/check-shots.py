#!/usr/bin/env python3
"""#1038 (from #1028) — fail-closed check that every capture shows the app, not the
splash or the home screen.

`simctl launch` + launchctl prove the process runs, not that its UI is up.
A splash (photo texture) or home screen (wallpaper) is colour-rich; the app's
UI is flat tokens. Measured: in the middle 40 % of the frame, the 8 most
common colours (median-cut, 256) cover >= 0.65 of the pixels on every app
screen, 0.19 on the splash, 0.11 on the home screen. Threshold 0.40.

Usage: python3 check-shots.py <png>...   (exit 1 lists the rejects)
"""
import sys

from PIL import Image

THRESHOLD = 0.40


def flat_share(path):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    band = img.crop((0, int(h * 0.3), w, int(h * 0.7))).resize((120, 160))
    hist = sorted(band.quantize(colors=256, method=Image.Quantize.MEDIANCUT).histogram(), reverse=True)
    return sum(hist[:8]) / sum(hist)


def main(paths):
    rejects = [(p, s) for p in paths for s in [flat_share(p)] if s < THRESHOLD]
    for path, share in rejects:
        print(f"NOT THE APP ({share:.2f} < {THRESHOLD}): {path}")
    if rejects:
        sys.exit(1)
    print(f"{len(paths)} captures show the app")


if __name__ == "__main__":
    main(sys.argv[1:])
