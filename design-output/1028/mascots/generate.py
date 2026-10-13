#!/usr/bin/env python3
"""#1028 C1/C2 — refined mascots: same characters and poses, crisper
outlines, plus one climbing prop each. Deterministic.

Inputs (never modified): the owner-approved masters in the app catalog
  ForceMascotLarge.imageset/r11-force-control-160.svg   (#894, R11)
  WorkoutMascotLarge.imageset/workout-r16-optical-160.svg (#875, R16)

Process, per character:
  1. rasterise the master at 10 px/unit (1600 px) with rsvg-convert;
  2. crispen: Gaussian blur (0.5 u) + 50% threshold, which removes
     sub-pixel hand-tracing jitter only. Larger radii smear small features:
     at 2.2 u the Workout bear lost its nose and smile while figure-wide IoU
     still read 0.97 (the verifier's local-drift gate now catches that);
  3. re-vectorise with potrace (curve-native, no raster smoothing in the
     output);
  4. compose the prop from hand-placed geometry (160-unit space), cut a
     knock-out halo for it out of the body (the masters' own device: the
     barbell slits, the pole gaps), and trace the prop the same way.

Output: design-output/1028/mascots/out/*.svg (plain #000 fills, template
rendering in-app, like the masters) + PNG proofs via render-sheet.py.

Usage (from the repo root):
  python3 design-output/1028/mascots/generate.py [out-dir]
Requires: rsvg-convert, potrace, Pillow.
"""
import hashlib
import os
import re
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
CATALOG = os.path.join(ROOT, "native/SendmeterNative/Resources/Assets.xcassets")
HERE = os.path.dirname(os.path.abspath(__file__))

SCALE = 10          # px per 160-unit
SIZE = 160 * SCALE
HALO = 1.8         # units — knock-out gap around a prop that overlaps the body

# ---------------------------------------------------------------------------
# Prop geometry (160-unit space). Props are built from rounded shapes so they
# share the masters' chunky, solid-fill language; knock-out gaps (>= 1.6 u)
# separate parts, exactly like the masters' own barbell slits.
# ---------------------------------------------------------------------------
K = 0.5523  # cubic Bezier circle constant


def _fmt(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def _xf(points, ox, oy, deg, dx, dy):
    import math
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [(dx + (x - ox) * c - (y - oy) * s, dy + (x - ox) * s + (y - oy) * c) for x, y in points]


def shape(corners, radii, ox=0.0, oy=0.0, deg=0.0, dx=0.0, dy=0.0):
    """Closed convex polygon (clockwise) with per-corner rounding, as a path.

    corners: [(x, y), ...] in local units; radii: one radius per corner.
    The result is rotated by `deg` about (ox, oy) and moved to (dx, dy).
    """
    import math
    n = len(corners)
    segs = []
    for i in range(n):
        p0, p1, p2 = corners[i - 1], corners[i], corners[(i + 1) % n]
        r = radii[i]
        v0 = (p0[0] - p1[0], p0[1] - p1[1])
        v2 = (p2[0] - p1[0], p2[1] - p1[1])
        l0, l2 = math.hypot(*v0), math.hypot(*v2)
        a = (p1[0] + v0[0] / l0 * r, p1[1] + v0[1] / l0 * r)
        b = (p1[0] + v2[0] / l2 * r, p1[1] + v2[1] / l2 * r)
        c1 = (a[0] + (p1[0] - a[0]) * K * 1.2, a[1] + (p1[1] - a[1]) * K * 1.2)
        c2 = (b[0] + (p1[0] - b[0]) * K * 1.2, b[1] + (p1[1] - b[1]) * K * 1.2)
        segs.append((a, c1, c2, b))
    pts = []
    for a, c1, c2, b in segs:
        pts += [a, c1, c2, b]
    pts = _xf(pts, ox, oy, deg, dx, dy)
    out = [f"M {_fmt(pts[0][0])} {_fmt(pts[0][1])}"]
    for i in range(n):
        a, c1, c2, b = pts[4 * i: 4 * i + 4]
        if i:
            out.append(f"L {_fmt(a[0])} {_fmt(a[1])}")
        out.append(f"C {_fmt(c1[0])} {_fmt(c1[1])} {_fmt(c2[0])} {_fmt(c2[1])} {_fmt(b[0])} {_fmt(b[1])}")
    out.append("Z")
    return " ".join(out)


def rrect(x, y, w, h, r, **kw):
    return shape([(x, y), (x + w, y), (x + w, y + h), (x, y + h)], [r] * 4, **kw)


def circle(cx, cy, r, **kw):
    return rrect(cx - r, cy - r, 2 * r, 2 * r, r, **kw)


def carabiner(dx, dy, deg=0.0, scale=1.0):
    """An offset-D carabiner centred at (dx, dy) as (add, cut) shape lists:
    a solid ring (outer minus inner) with one clean gate notch through the
    spine. Composed in raster and traced, so no even-odd artifacts."""
    kw = dict(ox=0.0, oy=0.0, deg=deg, dx=dx, dy=dy)

    def part(corners, radii):
        return shape([(x * scale, y * scale) for x, y in corners], [r * scale for r in radii], **kw)

    outer = part([(-7.5, -12.0), (7.0, -12.0), (5.2, 12.0), (-7.5, 12.0)], [7.4, 6.8, 5.0, 7.4])
    inner = part([(-4.3, -8.8), (3.9, -8.8), (2.4, 8.8), (-4.3, 8.8)], [4.2, 3.8, 2.4, 4.2])
    gate = part([(1.0, -6.8), (9.6, -6.8), (9.6, -3.6), (1.0, -3.6)], [0.8] * 4)
    return [outer], [inner, gate]


def sling(x0, y0, x1, y1, width):
    """A straight sling/strap from (x0, y0) to (x1, y1) with round ends."""
    import math
    length = math.hypot(x1 - x0, y1 - y0)
    deg = math.degrees(math.atan2(y1 - y0, x1 - x0))
    path = rrect(0.0, -width / 2, length, width, width / 2, ox=0.0, oy=0.0, deg=deg, dx=x0, dy=y0)
    return [path], []


MASTERS = {
    "force": {
        "src": "ForceMascotLarge.imageset/r11-force-control-160.svg",
        "out": "force-1028-160.svg",
        # Lump-removal radius (px at 10 px/u). 14 px starts eating the
        # barbell slits (knock-out count 5 -> 4), so 10.
        "smooth": 5.0,
        # C2 prop: a weighted-hang rig — a carabiner clipped onto the left
        # plate, in front of it, cut out of it by a knock-out halo (the same
        # device as the masters' barbell slits).
        "prop": lambda: [carabiner(15.0, 108.0, deg=-12.0, scale=1.2)],
        # Boxes the prop must stay inside (verify.py).
        "prop_boxes": [(2.0, 89.0, 29.0, 126.0)],
    },
    "workout": {
        "src": "WorkoutMascotLarge.imageset/workout-r16-optical-160.svg",
        "out": "workout-1028-160.svg",
        "smooth": 5.0,
        # C2 prop: a carabiner clipped to the climber's harness at the hip,
        # in front of the body, cut out of it by a knock-out halo.
        "prop": lambda: [carabiner(89.0, 116.0, deg=16.0, scale=1.15)],
        "prop_boxes": [(74.0, 97.0, 105.0, 135.0)],
    },
}


def sha256(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def rasterise(svg, png, size=SIZE):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), svg, "-o", png], check=True)
    return Image.open(png).convert("RGBA").getchannel("A")


def crispen(alpha, smooth):
    blurred = alpha.filter(ImageFilter.GaussianBlur(smooth))
    return blurred.point(lambda v: 255 if v >= 128 else 0)


def trace(mask, workdir):
    # potrace wants black ink on white: invert the alpha mask into a PBM.
    pbm = os.path.join(workdir, "mask.pbm")
    mask.point(lambda v: 0 if v else 255).convert("1").save(pbm)
    svg = os.path.join(workdir, "trace.svg")
    subprocess.run(
        ["potrace", pbm, "-s", "--flat", "-u", "10", "-t", "8", "-a", "1.1", "-O", "0.4", "-o", svg],
        check=True,
    )
    text = open(svg).read()
    group = re.search(r'<g transform="([^"]+)"', text).group(1)
    paths = re.findall(r'<path d="([^"]+)"', text, flags=re.S)
    return group, " ".join(" ".join(p.split()) for p in paths)


def shapes_mask(paths, workdir, name, stroke=0.0):
    """Rasterise a list of path strings (nonzero fill, optional stroke in
    units) at SIZE px."""
    svg = os.path.join(workdir, f"{name}.svg")
    body = "".join(
        f'<path d="{d}" fill="#000"'
        + (f' stroke="#000" stroke-width="{stroke * 2:g}" stroke-linejoin="round"' if stroke else "")
        + "/>"
        for d in paths
    )
    with open(svg, "w") as handle:
        handle.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 160">{body}</svg>')
    return rasterise(svg, os.path.join(workdir, f"{name}.png")).point(lambda v: 255 if v >= 128 else 0)


def compose_prop(spec, workdir):
    adds, cuts = [], []
    for add, cut in spec["prop"]():
        adds += add
        cuts += cut
    solid = shapes_mask(adds, workdir, "prop-add")
    prop = ImageChops.subtract(solid, shapes_mask(cuts, workdir, "prop-cut")) if cuts else solid
    halo = shapes_mask(adds, workdir, "prop-halo", stroke=HALO)
    return prop, halo


def svg_group(group, path):
    return (
        f'  <g transform="scale({1 / SCALE:g})">\n'
        f'    <g transform="{group}">\n'
        f'      <path fill="#000" d="{path}"/>\n'
        "    </g>\n"
        "  </g>\n"
    )


def build(key, out_dir):
    spec = MASTERS[key]
    src = os.path.join(CATALOG, spec["src"])
    digest = sha256(src)
    with tempfile.TemporaryDirectory() as workdir:
        alpha = rasterise(src, os.path.join(workdir, "master.png"))
        prop, halo = compose_prop(spec, workdir)
        body = ImageChops.subtract(crispen(alpha, spec["smooth"]), halo)
        body_group, body_path = trace(body, workdir)
        prop_group, prop_path = trace(prop, workdir)
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 160">\n'
        f"  <!-- #1028 C1/C2 candidate. Source: {spec['src']} sha256 {digest}. "
        "Generated by design-output/1028/mascots/generate.py; do not hand-edit. -->\n"
        + svg_group(body_group, body_path)
        + '  <g id="prop">\n'
        + svg_group(prop_group, prop_path).replace("  <g", "    <g", 1)
        + "  </g>\n"
        "</svg>\n"
    )
    path = os.path.join(out_dir, spec["out"])
    with open(path, "w") as handle:
        handle.write(svg)
    return path, digest


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "out")
    os.makedirs(out_dir, exist_ok=True)
    for key in MASTERS:
        path, digest = build(key, out_dir)
        print(f"{key}: {os.path.relpath(path, ROOT)}  (master sha256 {digest[:12]})")


if __name__ == "__main__":
    main()
