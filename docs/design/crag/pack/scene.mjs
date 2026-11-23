import { roo } from "./roo.mjs";

export const WEATHERS = { clear: "Clear", dawn: "Dawn", rain: "Rain", fog: "Fog" };
const ROO_POSE = { clear: "moon", dawn: "chalk", rain: "shelter", fog: "rest" };

function rand(seed) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
}

const SKY = {
  clear: ["#03051A", "#0B0F33", "#1A1D4A"],
  dawn: ["#060827", "#1E1A4C", "#5A3566"],
  rain: ["#04061A", "#0D1230", "#1B2142"],
  fog: ["#080B22", "#161B3C", "#2A3056"],
};

function facets(id, pts, bbox, r, light, tone, step = 46) {
  const [x0, y0, x1, y1] = bbox;
  const cols = Math.ceil((x1 - x0) / step) + 1, rows = Math.ceil((y1 - y0) / step) + 1;
  const g = [];
  for (let j = 0; j <= rows; j++) for (let i = 0; i <= cols; i++) g.push([x0 + i * step + (r() - 0.5) * step * 0.8, y0 + j * step + (r() - 0.5) * step * 0.8]);
  const at = (i, j) => g[j * (cols + 1) + i];
  let out = "";
  for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) {
    const a = at(i, j), b = at(i + 1, j), c = at(i + 1, j + 1), d = at(i, j + 1);
    for (const t of r() > 0.5 ? [[a, b, c], [a, c, d]] : [[a, b, d], [b, c, d]]) {
      const [p, q, s] = t;
      const nx = (q[1] - p[1]) * (s[0] - p[0]) - (q[0] - p[0]) * (s[1] - p[1]);
      const lit = Math.max(0, Math.min(1, 0.5 + light * (((p[0] + q[0] + s[0]) / 3 - x0) / (x1 - x0) - 0.5) + (r() - 0.5) * 0.5 + (nx > 0 ? 0.08 : -0.08)));
      const l = tone[0] + lit * tone[1];
      out += `<path d="M${p.map((v) => v.toFixed(0))}L${q.map((v) => v.toFixed(0))}L${s.map((v) => v.toFixed(0))}Z" fill="hsl(236 22% ${l.toFixed(1)}%)" stroke="hsl(236 26% ${(l - 2.5).toFixed(1)}%)" stroke-width="${(step / 38).toFixed(1)}"/>`;
    }
  }
  return `<clipPath id="${id}"><path d="${pts}"/></clipPath><g clip-path="url(#${id})">${out}</g>`;
}

export function rock(id, pts, bbox, seed, opts = {}) {
  const r = rand(seed);
  const pockets = (opts.pockets || []).map(([x, y, s]) => `<path d="M${x - 9 * s} ${y}C${x - 8 * s} ${y - 8 * s} ${x + 8 * s} ${y - 9 * s} ${x + 10 * s} ${y - 1 * s}C${x + 9 * s} ${y + 6 * s} ${x - 6 * s} ${y + 7 * s} ${x - 9 * s} ${y}Z" fill="#06071A" stroke="hsl(236 20% 22%)" stroke-width="${1.5 * (opts.line || 1)}"/>`).join("");
  const cracks = (opts.cracks || []).map((d) => `<path d="${d}" fill="none" stroke="#05061A" stroke-width="${3 * (opts.line || 1)}" stroke-linecap="round"/>`).join("");
  const rim = (opts.rim || []).map((d) => `<path d="${d}" fill="none" stroke="${opts.rimColor || "var(--rim)"}" stroke-width="${opts.rimWidth || 2.4}" stroke-linecap="round" opacity=".85"/>`).join("");
  return `<g>${facets(id, pts, bbox, r, opts.light ?? 0.6, opts.tone || [9, 13], opts.step)}${pockets}${cracks}<path d="${pts}" fill="none" stroke="#04051A" stroke-width="${4 * (opts.line || 1)}" stroke-linejoin="round"/>${rim}</g>`;
}

export function scene(W, H, weather = "clear", { roo: withRoo = true, seed = 7 } = {}) {
  const w = (1000 * W) / H, h = 1000;
  const r = rand(seed);
  const cx = w / 2;
  const sky = SKY[weather] || SKY.clear;
  const wide = w > 1000;
  const mx = wide ? w * 0.5 : cx + w * 0.26, my = wide ? 150 : 170, mr = wide ? 46 : 40;
  const stars = [...Array(Math.round(w / 4))].map(() => {
    const x = r() * w, y = r() * 560, s = r();
    return `<circle cx="${x.toFixed(0)}" cy="${y.toFixed(0)}" r="${(0.6 + s * 1.6).toFixed(1)}" fill="#EEF0FA" opacity="${(weather === "rain" ? 0.15 : weather === "fog" ? 0.3 : 0.35 + s * 0.6).toFixed(2)}"/>`;
  }).join("");

  const ox = cx - 500;
  const L = (x) => (ox + x).toFixed(0);
  const over = `M${L(-700)} ${h} L${L(-700)} 120 L${L(-120)} 40 L${L(180)} 70 L${L(360)} 150 L${L(470)} 260 L${L(520)} 380 L${L(470)} 440 L${L(380)} 470 L${L(330)} 560 L${L(300)} 700 L${L(250)} 760 L${L(120)} 790 Z`;
  const right = `M${L(640)} 790 L${L(600)} 640 L${L(640)} 520 L${L(740)} 430 L${L(900)} 400 L${L(1080)} 440 L${L(1700)} 470 L${L(1700)} ${h} Z`;
  const back = `M${L(-800)} 700 L${L(-200)} 560 L${L(200)} 600 L${L(500)} 540 L${L(820)} 600 L${L(1200)} 520 L${L(1800)} 620 L${L(1800)} ${h} L${L(-800)} ${h}Z`;
  const ground = `M${L(-800)} 760 L${L(1800)} 760 L${L(1800)} ${h} L${L(-800)} ${h}Z`;
  const slabs = [[180, 812, 170, 44, -4], [370, 834, 200, 52, 3], [600, 806, 150, 40, -6], [260, 900, 220, 60, 2], [520, 905, 180, 50, -3]]
    .map(([x, y, sw, sh, a]) => `<g transform="translate(${L(x)} ${y}) rotate(${a})"><rect x="${-sw / 2}" y="${-sh / 2}" width="${sw}" height="${sh}" rx="10" fill="#171A33" stroke="#05061A" stroke-width="3"/><path d="M${-sw / 2 + 10} ${-sh / 2 + 3} H${sw / 2 - 10}" stroke="hsl(236 22% 30%)" stroke-width="2" stroke-linecap="round"/></g>`).join("");
  const bag = `<g transform="translate(${L(640)} 792)"><path d="M-14 0 C-16 18 -12 26 0 26 C12 26 16 18 14 0Z" fill="#232743" stroke="#05061A" stroke-width="2.5"/><rect x="-15" y="-5" width="30" height="7" rx="3.5" fill="#2E3356" stroke="#05061A" stroke-width="2"/></g>`;

  const glow = weather === "dawn"
    ? `<linearGradient id="dg" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#FF9CC8" stop-opacity=".75"/><stop offset=".45" stop-color="#B58BFF" stop-opacity=".35"/><stop offset="1" stop-color="#A88BFF" stop-opacity="0"/></linearGradient>`
    : "";
  const dawnBand = weather === "dawn" ? `<rect x="0" y="60" width="${w}" height="640" fill="url(#dg)"/>` : "";
  const rain = weather === "rain"
    ? `<g stroke="#C9D2FF" stroke-width="1.6" stroke-linecap="round" opacity=".38">${[...Array(Math.round(w / 6))].map(() => { const x = r() * (w + 200), y = r() * h, l = 22 + r() * 26; return `<path d="M${x.toFixed(0)} ${y.toFixed(0)} l${(-l * 0.28).toFixed(0)} ${l.toFixed(0)}"/>`; }).join("")}</g>`
    : "";
  const fog = weather === "fog"
    ? [[470, 0.42, 90], [640, 0.5, 120], [800, 0.42, 110]].map(([y, o, t], i) => `<rect x="-50" y="${y - t / 2}" width="${w + 100}" height="${t}" fill="#B9BEDC" opacity="${o * 0.5}" filter="url(#fb)" transform="translate(${i % 2 ? -40 : 30} 0)"/>`).join("")
    : "";
  const moonO = weather === "rain" ? 0.45 : weather === "fog" ? 0.6 : 1;
  const rimC = weather === "dawn" ? "#E7C6F2" : "#C9C6F0";
    const [rx, ry] = wide ? [ox + 590, 780] : [ox + 425, 250];
  const rooSvg = withRoo ? `<g transform="translate(${rx - 68} ${ry - 148}) scale(.62)">${roo(ROO_POSE[weather], { size: 220 }).replace(/<svg [^>]*>/, '<svg x="0" y="0" width="220" height="275" viewBox="-120 -200 240 300" overflow="visible">')}</g>` : "";

  return `<svg class="scene" viewBox="0 0 ${w.toFixed(0)} ${h}" preserveAspectRatio="xMidYMax slice" width="100%" height="100%" role="img" aria-label="Night crag, ${WEATHERS[weather]}" style="--rim:${rimC}">
  <defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${sky[0]}"/><stop offset=".55" stop-color="${sky[1]}"/><stop offset="1" stop-color="${sky[2]}"/></linearGradient>
  <radialGradient id="halo"><stop offset=".33" stop-color="#E9E6FF" stop-opacity=".16"/><stop offset=".6" stop-color="#E9E6FF" stop-opacity=".06"/><stop offset="1" stop-color="#E9E6FF" stop-opacity="0"/></radialGradient>
  <filter id="fb" x="-10%" y="-50%" width="120%" height="200%"><feGaussianBlur stdDeviation="22"/></filter>${glow}</defs>
  <rect width="100%" height="100%" fill="url(#sky)"/>${stars}${dawnBand}
  <g opacity="${moonO}"><circle cx="${mx}" cy="${my}" r="${mr * 2.6}" fill="url(#halo)"/><circle cx="${mx}" cy="${my}" r="${mr}" fill="#E9EAF6"/><circle cx="${mx - mr * 0.3}" cy="${my - mr * 0.2}" r="${mr * 0.18}" fill="#CFD1E6"/><circle cx="${mx + mr * 0.35}" cy="${my + mr * 0.3}" r="${mr * 0.12}" fill="#CFD1E6"/></g>
  ${rock("rb", back, [ox - 800, 500, ox + 1800, h], seed + 3, { tone: [6, 7], light: 0.3 })}
  <path d="${ground}" fill="#0C0E24"/>
  ${rock("rr", right, [ox + 580, 380, ox + 1700, h], seed + 5, { tone: [8, 12], pockets: [[ox + 760, 520, 1.2], [ox + 900, 560, 1], [ox + 1040, 520, 1.1]], cracks: [`M${L(760)} 440 L${L(800)} 560 L${L(780)} 700`], rim: [`M${L(640)} 520 L${L(740)} 430 L${L(900)} 400 L${L(1080)} 440`] })}
  ${rock("ro", over, [ox - 700, 30, ox + 540, h], seed + 11, { tone: [8, 14], light: 0.9, pockets: [[ox + 120, 200, 1.6], [ox + 300, 260, 1.3], [ox + 420, 380, 1.1], [ox + 200, 420, 1.4], [ox + 60, 360, 1.2], [ox + 260, 560, 1.2], [ox - 40, 600, 1.4], [ox + 350, 470, 1]], cracks: [`M${L(180)} 70 L${L(140)} 240 L${L(220)} 380 L${L(160)} 560 L${L(200)} 760`, `M${L(-120)} 40 L${L(-60)} 300 L${L(-120)} 560`], rim: [`M${L(-120)} 40 L${L(180)} 70 L${L(360)} 150 L${L(470)} 260 L${L(520)} 380`] })}
  ${slabs}${bag}${rooSvg}${rain}${fog ? `<g>${fog}</g>` : ""}
  </svg>`;
}
