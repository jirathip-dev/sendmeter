import { readFileSync } from "node:fs";

const css = readFileSync(new URL("pack/crag.css", import.meta.url), "utf8");
const root = css.match(/:root\s*\{([^}]*)\}/)[1];
const tok = Object.fromEntries([...root.matchAll(/--([\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]));
const SCENE = {
  clear: ["#5A5C86", "#03051A"],
  dawn: ["#7A5A8E", "#060827"],
  rain: ["#3A3D5C", "#04061A"],
  fog: ["#6A6E8E", "#080B22"],
  pads: ["#A98C40", "#14172E"],
};
const SOLID = { "moonstone-top": "#5242AE", moonstone: "#46379A", "glint-violet": "#6E5CBE", "glint-teal": "#5961B0", "glint-pink": "#805FB3" };
const need = { body: 4.5, large: 3 };
const pairs = [
  ["fg", "card", "body"], ["mute", "card", "body"], ["link", "card", "body"], ["g", "card", "body"], ["a", "card", "body"], ["r", "card", "body"],
  ["link", "button", "body"], ["r", "bad-button", "body"],
  ["on-moonstone", "moonstone-top", "body"], ["on-moonstone", "moonstone", "body"], ["on-moonstone", "glint-violet", "body"], ["on-moonstone", "glint-teal", "body"], ["on-moonstone", "glint-pink", "body"],
  ["fg", "dim", "large"],
];

const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const lum = (h) => { const [r, g, b] = rgb(h).map(lin); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const hex = (cs) => "#" + cs.map((c) => Math.round(Math.min(255, c)).toString(16).padStart(2, "0")).join("");
const mix = (base, top, a) => hex(rgb(base).map((c, i) => c * (1 - a) + rgb(top)[i] * a));
const scale = (h, k) => hex(rgb(h).map((c) => c * k));
const rgba = (v) => { const m = v.match(/rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/); return [hex(m.slice(1, 4).map(Number)), Number(m[4])]; };

const [glass, ga] = rgba(tok.card);
let fails = 0;
console.log("| Weather | Text | On | Light part | Dark part | Needs | Result |\n|---|---|---|---|---|---|---|");
for (const [w, parts] of Object.entries(SCENE)) {
  const card = parts.map((p) => mix(p, glass, ga));
  const backs = {
    card,
    button: card.map((c) => mix(c, "#B9A8FF", 0.12)),
    "bad-button": card.map((c) => mix(c, "#FF9DB0", 0.1)),
    dim: parts.map((p) => scale(p, 0.55)),
  };
  for (const [fg, bg, size] of pairs) {
    const [onLight, onDark] = (backs[bg] || [SOLID[bg], SOLID[bg]]).map((b) => ratio(tok[fg], b));
    const ok = Math.min(onLight, onDark) >= need[size];
    if (!ok) fails++;
    console.log(`| ${w} | \`${fg}\` ${tok[fg]} | \`${bg}\` | ${onLight.toFixed(2)} | ${onDark.toFixed(2)} | ${need[size]} | ${ok ? "pass" : "FAIL"} |`);
  }
}
console.error(`${fails} failing of ${pairs.length * Object.keys(SCENE).length}`);
process.exitCode = fails ? 1 : 0;
