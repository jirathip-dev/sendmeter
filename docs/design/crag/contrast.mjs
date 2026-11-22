import { readFileSync } from "node:fs";

const css = readFileSync(new URL("headlamp.css", import.meta.url), "utf8");
const MODES = ["night", "dawn", "rain", "day", "golden", "fog"];
const DARKEST = { night: "#070B16", dawn: "#27304F", rain: "#2C3034", day: "#55545D", golden: "#4E4339", fog: "#4A4F52" };
const DIM = { dark: 0.45, light: 1.0 };
const need = { body: 4.5, large: 3 };
const pairs = [
  ["ink", "card", "body"], ["mute", "card", "body"], ["accent-ink", "card", "body"],
  ["good", "card", "body"], ["warn", "card", "body"], ["bad", "card", "body"],
  ["on-accent", "accent", "body"], ["on-bad", "bad", "body"], ["moon-num", "moon-lit", "large"], ["title", "dim", "large"],
];

const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const lum = (h) => { const [r, g, b] = rgb(h).map(lin); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const hex = (cs) => "#" + cs.map((c) => Math.round(Math.min(255, c)).toString(16).padStart(2, "0")).join("");
const mix = (base, top, a) => hex(rgb(base).map((c, i) => c * (1 - a) + rgb(top)[i] * a));
const scale = (h, k) => hex(rgb(h).map((c) => c * k));
const rgba = (v) => { const m = v.match(/rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/); return m && [hex(m.slice(1, 4).map(Number)), Number(m[4])]; };

const blocks = [...css.matchAll(/(:root\s*|\[data-mode[^{]*)\{([^}]*)\}/g)].map(([, sel, body]) => ({
  modes: sel.startsWith(":root") ? MODES : [...sel.matchAll(/"(\w+)"/g)].map((m) => m[1]),
  tok: Object.fromEntries([...body.matchAll(/--([\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()])),
}));

let fails = 0;
console.log("| Mode | Text | On | Light scene | Dark scene | Needs | Result |\n|---|---|---|---|---|---|---|");
for (const mode of MODES) {
  const tok = Object.assign({}, ...blocks.filter((b) => b.modes.includes(mode)).map((b) => b.tok));
  const [glass, a] = rgba(tok.glass);
  const light = lum(tok.ink) < 0.2;
  const [washC, washA] = rgba(tok.wash) || ["#000000", 0];
  const backs = {
    card: [mix(tok.lightest, glass, a), mix(DARKEST[mode], glass, a)],
    dim: light ? [mix(tok.lightest, washC, washA), mix(DARKEST[mode], washC, washA)] : [scale(tok.lightest, DIM.dark), scale(DARKEST[mode], DIM.dark)],
  };
  for (const [fg, bg, size] of pairs) {
    const [onLight, onDark] = (backs[bg] || [tok[bg], tok[bg]]).map((b) => ratio(tok[fg], b));
    const ok = Math.min(onLight, onDark) >= need[size];
    if (!ok) fails++;
    console.log(`| ${mode} | \`${fg}\` ${tok[fg]} | \`${bg}\` | ${onLight.toFixed(2)} | ${onDark.toFixed(2)} | ${need[size]} | ${ok ? "pass" : "FAIL"} |`);
  }
}
process.exitCode = fails ? 1 : 0;
