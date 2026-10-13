#!/usr/bin/env python3
"""#1028 — labelled before/after comparison sheets from the captured screens.

Reads  design-output/1028/screens/{before,after}/<device>/<label>-<state>-<scheme>.png
Writes design-output/1028/sheets/<device>-<state>.png
       (before dark | after dark | before light | after light; a state with
       no before capture — new F5 tabs — renders after-only)
and    design-output/1028/sheets/<device>-overview-<scheme>.png (every after
       state of one device, one row, for a quick phone read).

Deterministic: fixed layout, fixed font, PNG without timestamps. Usage
(repo root): python3 design-output/1028/tools/sheets.py
"""
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont, PngImagePlugin

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
BASE = os.path.join(ROOT, "design-output", "1028")
SCREENS = os.path.join(BASE, "screens")
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
    "force-guided-idle": "Force · connected, Guided, nothing armed",
    "force-guided-armed": "Force · connected, Guided, armed",
    "force-recording": "Force · recording",
    "force-handsfree-armed": "Force · connected, Hands-free, armed (waiting for pull)",
    "force-interrupted": "Force · interrupted (F3)",
    "force-guided-armed-bottom": "Force · scrolled to end (F5)",
    "dashboard": "Dashboard · readiness 38, load 0.66 (#1022/#1023)",
    "dashboard-bottom": "Dashboard · scrolled to end (F5)",
    "workout-bottom": "Workout · scrolled to end (F5)",
    "history-bottom": "History · scrolled to end (F5)",
    "settings-bottom": "Settings · scrolled to end (F5)",
    "watch-status": "Watch · Home / status",
    "watch-forceConnected-gauge": "Watch · Force gauge, connected",
    "watch-forceLive-gauge": "Watch · Force gauge, live pull",
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


def index(version, device):
    """{(state, scheme): path} for one version/device. Watch is dark-only."""
    folder = os.path.join(SCREENS, version, device)
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
    img.save(path, optimize=True, pnginfo=PngImagePlugin.PngInfo())
    print(os.path.relpath(path, ROOT))


def compare(device, state, before, after):
    width = TILE_W[device]
    columns = []
    for scheme in ("dark", "light"):
        if (state, scheme) in before:
            columns.append((f"before · {scheme}", before[(state, scheme)]))
        if (state, scheme) in after:
            columns.append((f"after · {scheme}", after[(state, scheme)]))
    if not columns:
        return
    tiles = [(label, tile(path, width)) for label, path in columns]
    tile_h = max(t.height for _, t in tiles)
    sheet = Image.new("RGB", (PAD + len(tiles) * (width + PAD), HEAD + CAP + tile_h + PAD), BG)
    draw = ImageDraw.Draw(sheet)
    draw.text((PAD, 16), STATE_TITLES.get(state, state), fill=INK, font=font(26, bold=True))
    for i, (label, img) in enumerate(tiles):
        x = PAD + i * (width + PAD)
        draw.text((x, HEAD), label, fill=INK if label.startswith("after") else MUTED, font=font(19))
        sheet.paste(img, (x, HEAD + CAP))
    save(sheet, os.path.join(SHEETS, f"{device}-{state}.png"))


def overview(device, after):
    width = TILE_W[device] // 2 + 40
    for scheme in ("dark", "light"):
        states = [s for s in ORDER if (s, scheme) in after]
        if not states:
            continue
        tiles = [(s, tile(after[(s, scheme)], width)) for s in states]
        tile_h = max(t.height for _, t in tiles)
        sheet = Image.new("RGB", (PAD + len(tiles) * (width + PAD), HEAD + CAP * 2 + tile_h + PAD), BG)
        draw = ImageDraw.Draw(sheet)
        draw.text((PAD, 16), f"#1028 after · {device} · {scheme}", fill=INK, font=font(26, bold=True))
        for i, (state, img) in enumerate(tiles):
            x = PAD + i * (width + PAD)
            title = STATE_TITLES.get(state, state).split(" · ", 1)[-1]
            words, lines, line = title.split(), [], ""
            for word in words:
                if len(line) + len(word) > 24 and line:
                    lines.append(line)
                    line = word
                else:
                    line = f"{line} {word}".strip()
            lines.append(line)
            draw.text((x, HEAD - 4), "\n".join(lines[:2]), fill=MUTED, font=font(15), spacing=2)
            sheet.paste(img, (x, HEAD + CAP * 2))
        save(sheet, os.path.join(SHEETS, f"{device}-overview-{scheme}.png"))


def main():
    devices = [d for d in ("17pro", "se", "watch") if os.path.isdir(os.path.join(SCREENS, "after", d))]
    if not devices:
        sys.exit("no screens/after/<device> folders")
    for device in devices:
        before, after = index("before", device), index("after", device)
        states = sorted({s for s, _ in after} | {s for s, _ in before}, key=lambda s: (ORDER + [s]).index(s))
        for state in states:
            compare(device, state, before, after)
        overview(device, after)


if __name__ == "__main__":
    main()
