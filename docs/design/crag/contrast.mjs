import { readFileSync } from "node:fs";

const css = readFileSync(new URL("themes.css", import.meta.url), "utf8");
const need = { body: 4.5, large: 3 };
const dimOf = { topo: 0.62, chalk: 0.62, journal: 0.8, headlamp: 0.45 };
const texOf = { topo: ["#E6EBF2", 0.08], chalk: ["#1A1A1A", 0.2], journal: ["#3C6496", 0.1], headlamp: ["#000000", 0] };
const pairs = [
  ["ink", "card", "body"], ["mute", "card", "body"], ["accent-ink", "card", "body"],
  ["on-accent", "accent", "body"], ["title", "dim", "large"],
];

const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const lum = (h) => { const [r, g, b] = rgb(h).map(lin); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const hex = (cs) => "#" + cs.map((c) => Math.round(c).toString(16).padStart(2, "0")).join("");
const mix = (base, top, a) => hex(rgb(base).map((c, i) => c * (1 - a) + rgb(top)[i] * a));
const scale = (h, k) => hex(rgb(h).map((c) => c * k));

let fails = 0;
console.log("| Theme | Text | On | Plain | Worst | Needs | Result |\n|---|---|---|---|---|---|---|");
for (const t of ["topo", "chalk", "journal", "headlamp"]) {
  const block = css.match(new RegExp(`\\[data-t="${t}"\\] \\{([\\s\\S]*?)\\n\\}`))[1];
  const tok = Object.fromEntries([...block.matchAll(/--([\w-]+):\s*(#[0-9A-Fa-f]{6})\b/g)].map((m) => [m[1], m[2]]));
  const [, r, g, b, a] = block.match(/--glass:\s*rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/);
  const glass = hex([r, g, b].map(Number));
  const cards = [mix(tok.lightest, glass, Number(a)), mix("#070B16", glass, Number(a))];
  tok.card = cards.reduce((x, y) => (Math.abs(lum(x) - lum(tok.ink)) < Math.abs(lum(y) - lum(tok.ink)) ? x : y));
  tok.title = "#FFFFFF";
  tok.dim = scale(tok.lightest, dimOf[t]);
  const [texC, texA] = texOf[t];
  for (const [fg, bg, size] of pairs) {
    const plain = ratio(tok[fg], tok[bg]);
    const worst = bg === "dim" ? plain : Math.min(plain, ratio(tok[fg], mix(tok[bg], texC, texA)));
    const ok = worst >= need[size];
    if (!ok) fails++;
    console.log(`| ${t} | \`${fg}\` ${tok[fg]} | \`${bg}\` ${tok[bg]} | ${plain.toFixed(2)} | ${worst.toFixed(2)} | ${need[size]} | ${ok ? "pass" : "FAIL"} |`);
  }
}
process.exitCode = fails ? 1 : 0;
