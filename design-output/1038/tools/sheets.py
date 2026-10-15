#!/usr/bin/env python3
"""#1038 — labelled before/after comparison sheets from the captured screens.

Reads  design-output/1038/screens/{before,after}/<device>/<version>-<device>-<state>-<scheme>.png
         (the staged 50 % copies, see stage-screens.sh)
Writes design-output/1038/sheets/<device>-<state>.png
         one state: before dark | after dark | before light | after light.
         A state with no build-58 counterpart renders after-only (dark | light).
         Where the same surface had another name on build 58 (Hands-free ->
         Free hold), BEFORE_FOR maps the after state to its before twin.
and    design-output/1038/sheets/<device>-overview-<scheme>.png
         every after state of one device in one row, for a phone read.

Deterministic: fixed layout, fixed font, PNG written without timestamps.
Usage (repo root): python3 design-output/1038/tools/sheets.py
"""
import os
import re

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
BASE = os.path.join(ROOT, "design-output", "1038")
SHEETS = os.path.join(BASE, "sheets")

BG = (0x2A, 0x2B, 0x33)
INK = (0xF4, 0xF4, 0xF8)
MUTED = (0xB9, 0xBA, 0xC6)
TILE_W = {"17pro": 402, "se": 375}  # point widths: 1x tiles, phone-legible
PAD = 22
HEAD = 64
CAP = 34

# Order = README order. Titles say what the screen proves.
STATE_TITLES = {
    "force-free-hold-armed": "Force · Free hold armed on connect; no live force on the tab (G1/G2/G3)",
    "force-free-hold-armed-last-pull": "Force · the last-pull summary in place of the gauge; opaque title bar (G6/H7)",
    "force-free-hold-waiting": "Free hold full screen · waiting for the next pull (G1)",
    "force-free-hold-recording": "Free hold full screen · recording: kg scale, fitted axis, labelled Best line (G1/H3-H6)",
    "force-free-hold-saved": "Free hold full screen · just saved, ready for the next pull (G1)",
    "force-guided-armed": "Force · Guided, protocol picked = armed, Start in the bar (G3/G4)",
    "force-zone-armed": "Force · suggested zone armed: target + intensity ticks by value (H1)",
    "force-disconnected": "Force · disconnected",
    "force-picker": "Movement & side · one tap applies and closes; swipe down keeps (G5/H2)",
    "force-picker-side": "Movement & side · a movement with no side history waits for the side (G5)",
    "force-bar-session": "Force · session in the bar: count + Finish (I1)",
    "force-held-pull": "Force · a held pull blocks Finish and says why (I3)",
    "force-after-finish": "Force · after Finish: session logged, Progressor disconnected (I2)",
    "guided-fullscreen-work": "Guided full screen · reference, reached from Start (unchanged)",
}
ORDER = list(STATE_TITLES)

# after state -> the build-58 capture of the same surface
BEFORE_FOR = {
    "force-free-hold-armed": "force-handsfree-armed",
    "force-free-hold-recording": "force-recording",
    "force-guided-armed": "force-guided-armed",
    "force-zone-armed": "force-zone-armed",
    "force-disconnected": "force-disconnected",
    "force-picker": "force-picker",
}


def font(size, bold=False):
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(path):
            f = ImageFont.truetype(path, size)
            if bold:
                try:
                    f.set_variation_by_name("Semibold")
                except (OSError, ValueError):
                    pass
            return f
    return ImageFont.load_default()


def index(version, device):
    folder = os.path.join(BASE, "screens", version, device)
    found = {}
    if not os.path.isdir(folder):
        return found
    for name in sorted(os.listdir(folder)):
        m = re.match(rf"{version}-{device}-(.+)-(dark|light)\.png$", name)
        if m:
            found[(m.group(1), m.group(2))] = os.path.join(folder, name)
    return found


def tile(path, width):
    im = Image.open(path).convert("RGB")
    h = round(im.height * width / im.width)
    return im.resize((width, h), Image.Resampling.LANCZOS)


def save(im, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path, format="PNG", optimize=True)  # no tEXt/tIME chunks


def compose(title, columns, width):
    """columns: [(caption, path)]"""
    tiles = [(cap, tile(p, width)) for cap, p in columns]
    th = max(t.height for _, t in tiles)
    W = PAD + len(tiles) * (width + PAD)
    H = HEAD + CAP + th + PAD
    sheet = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(sheet)
    d.text((PAD, 20), title, font=font(24, True), fill=INK)
    for i, (cap, t) in enumerate(tiles):
        x = PAD + i * (width + PAD)
        d.text((x, HEAD + 4), cap, font=font(18), fill=MUTED)
        sheet.paste(t, (x, HEAD + CAP))
    return sheet


def main():
    written = []
    for device, width in TILE_W.items():
        after = index("after", device)
        before = index("before", device)
        if not after:
            continue
        for state in ORDER:
            if (state, "dark") not in after:
                continue
            twin = BEFORE_FOR.get(state)
            cols = []
            for scheme in ("dark", "light"):
                if twin and (twin, scheme) in before:
                    cols.append((f"BEFORE · build 58 · {scheme}", before[(twin, scheme)]))
                if (state, scheme) in after:
                    cols.append((f"AFTER · {scheme}", after[(state, scheme)]))
            out = os.path.join(SHEETS, f"{device}-{state}.png")
            save(compose(f"{device.upper()} · {STATE_TITLES[state]}", cols, width), out)
            written.append(out)
        for scheme in ("dark", "light"):
            cols = [(s, after[(s, scheme)]) for s in ORDER if (s, scheme) in after]
            if not cols:
                continue
            out = os.path.join(SHEETS, f"{device}-overview-{scheme}.png")
            save(compose(f"{device.upper()} · after · {scheme} · every state", cols, 300), out)
            written.append(out)
    for path in written:
        print(os.path.relpath(path, ROOT))


if __name__ == "__main__":
    main()
