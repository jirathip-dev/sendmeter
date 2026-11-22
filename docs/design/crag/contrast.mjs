import { readFileSync } from "node:fs";

const pairs = [
  ["ink", "bg", "body"], ["mute", "bg", "body"], ["title-ink", "bg", "large"], ["hdr-ink", "bg", "large"],
  ["ink", "card", "body"], ["mute", "card", "body"], ["good", "card", "large"], ["grade-ink", "card", "large"],
  ["on-lead", "lead", "large"], ["plain-ink", "card", "large"],
  ["on-flash", "flash", "body"], ["on-send", "send", "body"],
  ["chip-on-ink", "chip-on", "body"], ["ink", "side", "body"], ["mute", "side", "body"],
  ["side-on-ink", "side-on", "body"], ["brand-ink", "side", "large"],
  ["tab-ink", "bar", "body"], ["tab-on-ink", "bar", "body"],
];
const need = { body: 4.5, large: 3 };
const grey = "#808080";

const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const lum = (h) => { const [r, g, b] = rgb(h).map(lin); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const mix = (base, top, a) => "#" + rgb(base).map((c, i) => Math.round(c * (1 - a) + rgb(top)[i] * a).toString(16).padStart(2, "0")).join("");
const hex = (r, g, b) => "#" + [r, g, b].map((c) => Number(c).toString(16).padStart(2, "0")).join("");

let fails = 0;
for (const dir of ["golden", "blue", "faded"]) {
  const css = readFileSync(new URL(`${dir}.css`, import.meta.url), "utf8");
  const tok = Object.fromEntries([...css.matchAll(/--([\w-]+):\s*(#[0-9A-Fa-f]{6})\b/g)].map((m) => [m[1], m[2]]));
  const grainA = Number(css.match(/--grain-a:\s*([\d.]+)/)[1]);
  const tint = css.match(/--bg-tex:[^;]*?rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/);
  const textured = (name) => {
    const base = name === "bg" && tint ? mix(tok.bg, hex(tint[1], tint[2], tint[3]), Number(tint[4])) : tok[name];
    return mix(base, grey, grainA);
  };
  console.log(`\n### ${dir}\n\n| Text | On | Plain | On texture | Needs | Result |\n|---|---|---|---|---|---|`);
  for (const [fg, bg, size] of pairs) {
    const plain = ratio(tok[fg], tok[bg]);
    const worst = ratio(tok[fg], textured(bg));
    const ok = Math.min(plain, worst) >= need[size];
    if (!ok) fails++;
    console.log(`| \`${fg}\` ${tok[fg]} | \`${bg}\` ${tok[bg]} | ${plain.toFixed(2)} | ${worst.toFixed(2)} | ${need[size]} | ${ok ? "pass" : "FAIL"} |`);
  }
}
process.exitCode = fails ? 1 : 0;
