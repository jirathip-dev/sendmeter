#!/usr/bin/env python3
"""#1028 mascots — verifier + proof sheet. Exits non-zero on any failure.

Gates per character:
  * the approved master is byte-identical to its pinned sha256 (never edited);
  * the generator is deterministic (a fresh run is byte-identical);
  * C1 same character + pose: the refined body (prop masked out) overlaps
    the master at IoU >= 0.97, the knock-out (hole) count is unchanged, AND
    no 8 x 8-unit window differs from the master by more than 6 % (faces,
    noses, smiles and slits cannot be smeared away while the figure-wide
    IoU stays high);
  * C2 prop: entirely inside its declared boxes, separated from the
    character by a knock-out gap >= 1.2 units (its halo).

Writes the before/after sheet (dark + light, shared-palette primary) to
design-output/1028/mascots/mascot-sheet.png.

Usage (repo root): python3 design-output/1028/mascots/verify.py
"""
import hashlib
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import generate  # noqa: E402

PX = 4  # px per unit for the gates (640 px)
SIZE = 160 * PX
LOCAL_DRIFT = 0.06  # max differing-pixel fraction in any 8 x 8 u window

PINS = {
    "force": "6802e9439ff2fbcd70f60e7f04baf2196c33cf17de6ad309716966221ede6380",
    "workout": "b3bfeba871443d8913e0d2b83ce2551f8ab1ad18d7a5f3165481e4ebe6068338",
}
# Shared palette primary (SendmeterPalette.primary / primaryText) and canvases.
THEMES = {
    "dark": {"bg": (0x17, 0x18, 0x1F), "ink": (0xA9, 0xAD, 0xE3), "text": (0xB9, 0xBA, 0xC6)},
    "light": {"bg": (0xFF, 0xFF, 0xFF), "ink": (0x5B, 0x5F, 0xC7), "text": (0x52, 0x52, 0x5C)},
}


def sha256(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def mask(svg, size=SIZE):
    with tempfile.TemporaryDirectory() as workdir:
        png = os.path.join(workdir, "m.png")
        subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), svg, "-o", png], check=True)
        return Image.open(png).convert("RGBA").getchannel("A").point(lambda v: 255 if v >= 128 else 0)


def worst_local_drift(master, body, halo, window=8, step=2):
    """C1 per feature: the largest fraction of differing pixels in any
    window x window-unit square (outside the prop halo). Whole-figure IoU
    averages a lost face away (the R16 muzzle at blur 22 still scored
    0.97); a local window cannot. Returns (fraction, (x, y) units)."""
    diff = ImageChops.subtract(ImageChops.logical_xor(master.convert("1"), body.convert("1")).convert("L"), halo)
    px = diff.load()
    integral = [[0] * (SIZE + 1) for _ in range(SIZE + 1)]
    for y in range(SIZE):
        run = 0
        for x in range(SIZE):
            run += 1 if px[x, y] else 0
            integral[y + 1][x + 1] = integral[y][x + 1] + run
    win, stride, worst = window * PX, step * PX, (0.0, (0, 0))
    for y0 in range(0, SIZE - win + 1, stride):
        for x0 in range(0, SIZE - win + 1, stride):
            count = (integral[y0 + win][x0 + win] - integral[y0][x0 + win]
                     - integral[y0 + win][x0] + integral[y0][x0])
            worst = max(worst, (count / (win * win), (x0 / PX, y0 / PX)))
    return worst


def holes(img):
    """Count background components NOT connected to the border (knock-outs)."""
    w, h = img.size
    px = img.load()
    seen = bytearray(w * h)
    count = 0
    for sy in range(h):
        for sx in range(w):
            if px[sx, sy] or seen[sy * w + sx]:
                continue
            stack = [(sx, sy)]
            seen[sy * w + sx] = 1
            touches = False
            size = 0
            while stack:
                x, y = stack.pop()
                size += 1
                if x in (0, w - 1) or y in (0, h - 1):
                    touches = True
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < w and 0 <= ny < h and not px[nx, ny] and not seen[ny * w + nx]:
                        seen[ny * w + nx] = 1
                        stack.append((nx, ny))
            if not touches and size >= 4:
                count += 1
    return count


def box_mask(boxes):
    m = Image.new("L", (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(m)
    for x0, y0, x1, y1 in boxes:
        draw.rectangle([x0 * PX, y0 * PX, x1 * PX, y1 * PX], fill=255)
    return m


def iou(a, b):
    ap, bp = a.load(), b.load()
    inter = union = 0
    for y in range(SIZE):
        for x in range(SIZE):
            av, bv = ap[x, y] > 0, bp[x, y] > 0
            inter += av and bv
            union += av or bv
    return inter / union if union else 1.0


def subtract(a, m):
    out = a.copy()
    op, mp = out.load(), m.load()
    for y in range(SIZE):
        for x in range(SIZE):
            if mp[x, y]:
                op[x, y] = 0
    return out


def min_gap_units(prop_only, body):
    """Smallest distance (units) from any prop pixel to any body pixel."""
    pp, bp = prop_only.load(), body.load()
    prop_px = [(x, y) for y in range(SIZE) for x in range(SIZE) if pp[x, y]]
    best = 10**9
    r = 12 * PX
    for x, y in prop_px[:: max(1, len(prop_px) // 1500)]:
        for dy in range(-r, r + 1):
            yy = y + dy
            if not 0 <= yy < SIZE:
                continue
            for dx in range(-r, r + 1):
                xx = x + dx
                if 0 <= xx < SIZE and bp[xx, yy]:
                    best = min(best, dx * dx + dy * dy)
    return (best ** 0.5) / PX if best < 10**9 else float("inf")


def main():
    failures = []
    out_dir = os.path.join(HERE, "out")
    results = {}
    with tempfile.TemporaryDirectory() as fresh:
        subprocess.run([sys.executable, os.path.join(HERE, "generate.py"), fresh], check=True,
                       stdout=subprocess.DEVNULL, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        for key, spec in generate.MASTERS.items():
            master_path = os.path.join(generate.CATALOG, spec["src"])
            digest = sha256(master_path)
            if digest != PINS[key]:
                failures.append(f"{key}: approved master changed ({digest})")
            committed = os.path.join(out_dir, spec["out"])
            if not os.path.exists(committed):
                failures.append(f"{key}: missing {committed}")
                continue
            if sha256(committed) != sha256(os.path.join(fresh, spec["out"])):
                failures.append(f"{key}: generator is not deterministic / output is stale")

            # Split the committed SVG exactly: the body (potrace group) and
            # the prop (the last <path>) render separately — no box clipping,
            # so a prop that escapes its box or touches the body is caught.
            text = open(committed).read()
            prop_tag = text[text.index('  <g id="prop"'):text.rindex("</svg>")]
            body_svg = os.path.join(fresh, f"{key}-body.svg")
            prop_svg = os.path.join(fresh, f"{key}-prop.svg")
            open(body_svg, "w").write(text.replace(prop_tag, ""))
            open(prop_svg, "w").write(text[:text.index("  <g ")] + prop_tag + "</svg>\n")

            master = mask(master_path)
            body = mask(body_svg)
            prop_only = mask(prop_svg)
            region = box_mask(spec["prop_boxes"])
            with tempfile.TemporaryDirectory() as work:
                _, halo = generate.compose_prop(spec, work)
            halo = halo.resize((SIZE, SIZE))
            # C1: compare outside the prop's halo (inside it the body is cut
            # on purpose); topology with the halo refilled where the master
            # had ink.
            score = iou(subtract(body, halo), subtract(master, halo))
            refilled = body.copy()
            refilled.paste(255, mask=ImageChops.multiply(halo, master))
            h_master, h_body = holes(master), holes(refilled)
            outside = subtract(prop_only, region)
            gap = min_gap_units(prop_only, body)
            results[key] = dict(iou=score, holes=(h_master, h_body), gap=gap)
            if score < 0.97:
                failures.append(f"{key}: body IoU {score:.4f} < 0.97 (pose drift)")
            if h_master != h_body:
                failures.append(f"{key}: knock-outs {h_master} -> {h_body} (a facial/detail hole was lost or added)")
            drift, at = worst_local_drift(master, body, halo)
            results[key]["drift"] = (drift, at)
            if drift > LOCAL_DRIFT:
                failures.append(f"{key}: local drift {drift:.3f} > {LOCAL_DRIFT} at {at} u (a feature was smeared)")
            if not prop_only.getbbox():
                failures.append(f"{key}: no prop rendered")
            if outside.getbbox():
                failures.append(f"{key}: prop escapes its declared boxes at {[v / PX for v in outside.getbbox()]}")
            if gap < 1.2:
                failures.append(f"{key}: prop gap {gap:.2f} u < 1.2 u from the character")

    for key, r in results.items():
        print(f"{key}: body IoU {r['iou']:.4f}  knock-outs {r['holes'][0]}->{r['holes'][1]}  "
              f"local drift {r['drift'][0]:.3f} at {r['drift'][1]} u  prop gap {r['gap']:.2f} u")
    sheet(os.path.join(HERE, "mascot-sheet.png"))
    if failures:
        print("FAIL\n  " + "\n  ".join(failures))
        sys.exit(1)
    print("PASS")


def tint(alpha, ink, bg):
    img = Image.new("RGB", alpha.size, bg)
    img.paste(Image.new("RGB", alpha.size, ink), mask=alpha)
    return img


def sheet(path):
    cell = 300
    pad = 24
    label_h = 34
    keys = list(generate.MASTERS)
    cols = [(k, v) for k in keys for v in ("before", "after")]
    width = pad + len(cols) * (cell + pad)
    height = label_h + len(THEMES) * (cell + pad) + pad
    canvas = Image.new("RGB", (width, height), (0x5A, 0x5B, 0x63))
    draw = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 18)
    except OSError:
        font = ImageFont.load_default()
    for c, (key, version) in enumerate(cols):
        spec = generate.MASTERS[key]
        src = os.path.join(generate.CATALOG, spec["src"]) if version == "before" else os.path.join(HERE, "out", spec["out"])
        x = pad + c * (cell + pad)
        name = {"force": "Force (R11)", "workout": "Workout (R16)"}[key]
        draw.text((x, 8), f"{name} · {'before' if version == 'before' else 'after: crisper + prop'}", fill=(240, 240, 244), font=font)
        alpha = mask(src, size=cell - 40)
        for r, theme in enumerate(THEMES.values()):
            y = label_h + r * (cell + pad)
            tile = Image.new("RGB", (cell, cell), theme["bg"])
            tile.paste(tint(alpha, theme["ink"], theme["bg"]), (20, 20))
            canvas.paste(tile, (x, y))
    canvas.save(path, optimize=True)
    print(f"sheet: {os.path.relpath(path, generate.ROOT)}")


if __name__ == "__main__":
    main()
