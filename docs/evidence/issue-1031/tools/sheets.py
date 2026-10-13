#!/usr/bin/env python3
"""#1031 (from #1030/#1028's tools) — labelled before / after / approved sheets.

Reads  docs/evidence/issue-1031/screens/{before,after}/<device>/<label>-<state>-<scheme>.png
and    the APPROVED #1028 captures, extracted from the design commit:
       git archive fc1d8ada design-output/1028/screens | tar -x -C <dir>
       python3 sheets.py <dir>/design-output/1028/screens
Writes docs/evidence/issue-1031/sheets/<device>-<state>.png
       (before | after | approved, dark then light; Watch is dark-only)

Deterministic: fixed layout, fixed font, PNG without timestamps.
"""
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont, PngImagePlugin

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
BASE = os.path.join(ROOT, "docs", "evidence", "issue-1031")
SCREENS = os.path.join(BASE, "screens")
APPROVED = sys.argv[1] if len(sys.argv) > 1 else None
SHEETS = os.path.join(BASE, "sheets")

BG = (0x2A, 0x2B, 0x33)
INK = (0xF4, 0xF4, 0xF8)
MUTED = (0xB9, 0xBA, 0xC6)
TILE_W = {"17pro": 430, "se": 375, "watch": 260}
PAD = 22
HEAD = 64
CAP = 34

STATE_TITLES = {
    "force-disconnected": "Force · disconnected",
    "force-guided-idle": "Force · connected idle, Guided, nothing armed",
    "force-guided-armed": "Force · connected, Guided, armed",
    "force-guided-armed-bottom": "Force · scrolled to end (F5 + P4)",
    "force-guided-recording": "Force · Guided recording (P1, P8, F4)",
    "force-recording": "Force · Hands-free recording (P1, P8; SE = P9)",
    "force-handsfree-armed": "Force · Hands-free armed (P2, P8)",
    "force-interrupted": "Force · connection lost (P11)",
    "force-held": "Force · #1004 recovery: held pull (Save / Discard)",
}
ORDER = list(STATE_TITLES)


def font(size, bold=False):
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        if os.path.exists(path):
            f = ImageFont.truetype(path, size)
            if bold:
                try:
                    f.set_variation_by_name("Semibold")
                except (OSError, ValueError):
                    pass
            return f
    return ImageFont.load_default()


def index(version, device, root=SCREENS):
    """{(state, scheme): path} for one version/device. Watch is dark-only."""
    folder = os.path.join(root, version, device)
    found = {}
    if not os.path.isdir(folder):
        return found
    for name in sorted(os.listdir(folder)):
        m = re.match(rf"{version}-(.+?)(?:-(dark|light))?\.png$", name)
        if m:
            found[(m.group(1), m.group(2) or "dark")] = os.path.join(folder, name)
    return found


def tile(path, width):
    img = Image.open(path).convert("RGB")
    height = round(img.height * width / img.width)
    return img.resize((width, height), Image.LANCZOS)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Sheets are for viewing only (the measured pixels live in screens/), so a
    # 256-colour palette keeps the repo copy ~2.5x smaller with no visible loss.
    img = img.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    img.save(path, optimize=True, pnginfo=PngImagePlugin.PngInfo())
    print(os.path.relpath(path, ROOT))


def compare(device, state, before, after, approved):
    width = TILE_W[device]
    columns = []
    for scheme in ("dark", "light"):
        if (state, scheme) in before:
            columns.append((f"before · {scheme}", before[(state, scheme)]))
        if (state, scheme) in after:
            columns.append((f"after · {scheme}", after[(state, scheme)]))
        if (state, scheme) in approved:
            columns.append((f"approved #1028 · {scheme}", approved[(state, scheme)]))
    if not columns:
        return
    tiles = [(label, tile(path, width)) for label, path in columns]
    tile_h = max(t.height for _, t in tiles)
    sheet = Image.new("RGB", (PAD + len(tiles) * (width + PAD), HEAD + CAP + tile_h + PAD), BG)
    draw = ImageDraw.Draw(sheet)
    draw.text((PAD, 16), STATE_TITLES.get(state, state), fill=INK, font=font(26, bold=True))
    for i, (label, img) in enumerate(tiles):
        x = PAD + i * (width + PAD)
        draw.text((x, HEAD), label, fill=MUTED if label.startswith("before") else INK, font=font(19))
        sheet.paste(img, (x, HEAD + CAP))
    save(sheet, os.path.join(SHEETS, f"{device}-{state}.png"))


def main():
    devices = [d for d in ("17pro", "se", "watch") if os.path.isdir(os.path.join(SCREENS, "after", d))]
    if not devices:
        sys.exit("no screens/after/<device> folders")
    for device in devices:
        before, after = index("before", device), index("after", device)
        approved = index("after", device, APPROVED) if APPROVED else {}
        states = sorted({s for s, _ in after} | {s for s, _ in before}, key=lambda s: (ORDER + [s]).index(s))
        for state in states:
            compare(device, state, before, after, approved)


if __name__ == "__main__":
    main()
