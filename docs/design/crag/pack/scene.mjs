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

export function rock(id, pts, bbox, seed, opts = {}) {
  const [x0, y0, x1, y1] = bbox;
  const k = (x1 - x0) / 1000;
  const [lo, hi] = opts.tone || [9, 13];
  const dir = opts.lightFrom === "left" ? ["1", "0.3", "0", "0.8"] : ["0", "0.2", "1", "0.8"];
  const blur = (opts.blur || 26) * Math.max(k, 0.6);
  const shade = (opts.shade || []).map((d) => `<path d="${d}" fill="hsl(236 30% ${(lo * 0.45).toFixed(1)}%)" opacity=".85" filter="url(#${id}-b)"/>`).join("");
  const lit = (opts.lit || []).map((d) => `<path d="${d}" fill="hsl(240 22% ${(lo + hi * 1.7).toFixed(1)}%)" opacity=".8" filter="url(#${id}-b)"/>`).join("");
  const line = opts.line || 1;
  const faces = (opts.faces || []).map((d) => `<path d="${d}" fill="url(#${id}-f)"/><path d="${d}" fill="none" stroke="hsl(238 24% ${(lo + hi + 10).toFixed(1)}%)" stroke-width="${2.4 * line}" opacity=".5"/>`).join("");
  const pockets = (opts.pockets || []).map(([x, y, s]) => `<ellipse cx="${x}" cy="${y}" rx="${11 * s}" ry="${8 * s}" fill="hsl(236 30% ${(lo * 0.35).toFixed(1)}%)"/><path d="M${x - 9 * s} ${y + 3 * s} Q${x} ${y + 10 * s} ${x + 9 * s} ${y + 3 * s}" fill="none" stroke="hsl(238 22% ${(lo + hi + 6).toFixed(1)}%)" stroke-width="${2.2 * line}" stroke-linecap="round" opacity=".8"/>`).join("");
  const cracks = (opts.cracks || []).map((d) => `<path d="${d}" fill="none" stroke="#05061A" stroke-width="${3.2 * line}" stroke-linecap="round" stroke-linejoin="round"/>`).join("");
  const rim = (opts.rim || []).map((d) => `<path d="${d}" fill="none" stroke="${opts.rimColor || "var(--rim)"}" stroke-width="${opts.rimWidth || 2.4}" stroke-linecap="round" opacity=".85"/>`).join("");
  return `<g><defs><linearGradient id="${id}-g" x1="${dir[0]}" y1="${dir[1]}" x2="${dir[2]}" y2="${dir[3]}"><stop offset="0" stop-color="hsl(238 20% ${(lo + hi * 1.15).toFixed(1)}%)"/><stop offset="1" stop-color="hsl(236 24% ${lo.toFixed(1)}%)"/></linearGradient>
  <linearGradient id="${id}-f" x1="1" y1="0" x2="0" y2="1"><stop offset="0" stop-color="hsl(238 22% ${(lo + hi * 0.45).toFixed(1)}%)"/><stop offset="1" stop-color="hsl(236 30% ${(lo * 0.55).toFixed(1)}%)"/></linearGradient><clipPath id="${id}"><path d="${pts}"/></clipPath><filter id="${id}-b" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="${blur.toFixed(1)}"/></filter></defs>
  <path d="${pts}" fill="url(#${id}-g)"/><g clip-path="url(#${id})">${lit}${faces}${shade}${pockets}${cracks}</g><path d="${pts}" fill="none" stroke="#04051A" stroke-width="${4 * line}" stroke-linejoin="round"/>${rim}</g>`;
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
  const over = `M${L(-700)} ${h} L${L(-700)} 200 C${L(-560)} 80 ${L(-300)} 30 ${L(-40)} 40 C${L(160)} 50 ${L(330)} 120 ${L(430)} 215 C${L(510)} 285 ${L(615)} 318 ${L(612)} 366 C${L(608)} 410 ${L(520)} 418 ${L(440)} 430 C${L(410)} 436 ${L(395)} 452 ${L(380)} 470 C${L(300)} 540 ${L(250)} 660 ${L(220)} 776 L${L(-700)} 776 Z`;
  const roof = `M${L(560)} 310 C${L(420)} 300 ${L(200)} 380 ${L(80)} 480 C${L(0)} 560 ${L(-30)} 680 ${L(-40)} 776 L${L(230)} 776 C${L(250)} 660 ${L(300)} 540 ${L(380)} 470 C${L(400)} 444 ${L(440)} 436 ${L(500)} 426 C${L(570)} 416 ${L(612)} 400 ${L(604)} 356 C${L(598)} 330 ${L(580)} 314 ${L(560)} 310Z`;
  const overShade = [`M${L(-40)} 700 C${L(100)} 660 ${L(240)} 680 ${L(300)} 720 L${L(300)} 800 L${L(-40)} 800Z`, `M${L(-700)} 560 C${L(-500)} 620 ${L(-200)} 600 ${L(-60)} 700 L${L(-60)} 800 L${L(-700)} 800Z`];
  const overLit = [`M${L(-560)} 120 C${L(-300)} 60 ${L(100)} 70 ${L(300)} 150 C${L(380)} 190 ${L(420)} 230 ${L(400)} 260 C${L(250)} 200 ${L(-200)} 170 ${L(-560)} 230Z`];
  const right = `M${L(640)} 790 C${L(610)} 690 ${L(660)} 590 ${L(780)} 540 C${L(900)} 494 ${L(1060)} 500 ${L(1180)} 540 C${L(1320)} 584 ${L(1500)} 560 ${L(1700)} 590 L${L(1700)} ${h} Z`;
  const back = `M${L(-800)} 700 C${L(-500)} 600 ${L(-200)} 560 ${L(100)} 600 C${L(350)} 630 ${L(500)} 540 ${L(800)} 580 C${L(1100)} 620 ${L(1300)} 520 ${L(1800)} 610 L${L(1800)} ${h} L${L(-800)} ${h}Z`;
  const ground = `M${L(-800)} 760 L${L(1800)} 760 L${L(1800)} ${h} L${L(-800)} ${h}Z`;
  const pads = [[-260, 812, 270, 66, 2], [60, 804, 270, 68, -3], [350, 798, 240, 62, 2], [620, 810, 250, 66, -2], [920, 802, 280, 68, 3], [1220, 812, 260, 66, -1], [-150, 900, 320, 84, 1], [200, 892, 300, 86, -1], [530, 902, 290, 82, 2], [860, 896, 310, 86, -2], [1190, 902, 300, 84, 1]]
    .map(([x, y, pw, ph, a]) => `<g transform="translate(${L(x)} ${y}) rotate(${a})"><rect x="${-pw / 2}" y="${-ph / 2}" width="${pw}" height="${ph + 18}" rx="12" fill="#14172E" stroke="#05061A" stroke-width="3"/><rect x="${-pw / 2}" y="${-ph / 2}" width="${pw}" height="${ph}" rx="12" fill="url(#pad)"/><rect x="${-pw / 2}" y="${-ph / 2}" width="${pw}" height="${ph}" rx="12" fill="#0A0D2A" opacity="${weather === "clear" || weather === "dawn" ? 0.32 : 0.42}" stroke="#05061A" stroke-width="3"/><path d="M${-pw / 2 + 12} ${-ph / 2 + 2} H${pw / 2 - 12}" stroke="#FFF" stroke-width="2.4" stroke-linecap="round" opacity=".35"/></g>`).join("");
  const bag = `<g transform="translate(${L(640)} 778)"><path d="M-14 0 C-16 18 -12 26 0 26 C12 26 16 18 14 0Z" fill="#E4E6F2" opacity=".82" stroke="#05061A" stroke-width="2.5"/><rect x="-15" y="-5" width="30" height="7" rx="3.5" fill="#A99CF0" stroke="#05061A" stroke-width="2"/></g>`;

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
    const [rx, ry] = wide ? [ox + 540, 786] : [ox + 425, 250];
  const rooSvg = withRoo ? `<g transform="translate(${rx - 68} ${ry - 148}) scale(.62)">${roo(ROO_POSE[weather], { size: 220 }).replace(/<svg [^>]*>/, '<svg x="0" y="0" width="220" height="275" viewBox="-120 -200 240 300" overflow="visible">')}</g>` : "";

  return `<svg class="scene" viewBox="0 0 ${w.toFixed(0)} ${h}" preserveAspectRatio="xMidYMax slice" width="100%" height="100%" role="img" aria-label="Night crag, ${WEATHERS[weather]}" style="--rim:${rimC}">
  <defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${sky[0]}"/><stop offset=".55" stop-color="${sky[1]}"/><stop offset="1" stop-color="${sky[2]}"/></linearGradient>
  <radialGradient id="halo"><stop offset=".33" stop-color="#E9E6FF" stop-opacity=".16"/><stop offset=".6" stop-color="#E9E6FF" stop-opacity=".06"/><stop offset="1" stop-color="#E9E6FF" stop-opacity="0"/></radialGradient>
  <pattern id="pad" width="66" height="66" patternUnits="userSpaceOnUse" patternTransform="rotate(40)"><rect width="22" height="66" fill="#EE6FA2"/><rect x="22" width="22" height="66" fill="#33BDB1"/><rect x="44" width="22" height="66" fill="#F4C84A"/></pattern><filter id="fb" x="-10%" y="-50%" width="120%" height="200%"><feGaussianBlur stdDeviation="22"/></filter>${glow}</defs>
  <rect width="100%" height="100%" fill="url(#sky)"/>${stars}${dawnBand}
  <g opacity="${moonO}"><circle cx="${mx}" cy="${my}" r="${mr * 2.6}" fill="url(#halo)"/><circle cx="${mx}" cy="${my}" r="${mr}" fill="#E9EAF6"/><circle cx="${mx - mr * 0.3}" cy="${my - mr * 0.2}" r="${mr * 0.18}" fill="#CFD1E6"/><circle cx="${mx + mr * 0.35}" cy="${my + mr * 0.3}" r="${mr * 0.12}" fill="#CFD1E6"/></g>
  ${rock("rb", back, [ox - 800, 500, ox + 1800, h], seed + 3, { tone: [5, 4] })}
  <path d="${ground}" fill="#0C0E24"/>
  ${rock("rr", right, [ox + 580, 480, ox + 1700, h], seed + 5, { tone: [8, 11], shade: [`M${L(600)} 700 C${L(900)} 660 ${L(1300)} 700 ${L(1700)} 680 L${L(1700)} 800 L${L(600)} 800Z`], pockets: [[ox + 820, 620, 1.1], [ox + 1000, 580, 1]], cracks: [`M${L(900)} 500 C${L(880)} 580 ${L(930)} 640 ${L(900)} 780`], rim: [`M${L(700)} 566 C${L(740)} 550 ${L(760)} 546 ${L(780)} 540 C${L(900)} 494 ${L(1060)} 500 ${L(1180)} 540`] })}
  ${rock("ro", over, [ox - 700, 30, ox + 600, h], seed + 11, { tone: [9, 16], faces: [roof], shade: overShade, lit: overLit, pockets: [[ox + 400, 360, 1.2], [ox + 300, 420, 1.1], [ox + 180, 520, 1.3], [ox + 120, 640, 1.1], [ox + 60, 230, 1.2], [ox - 160, 330, 1.4], [ox - 380, 470, 1.2], [ox - 220, 620, 1.1]], cracks: [`M${L(330)} 330 C${L(290)} 420 ${L(250)} 470 ${L(210)} 560 C${L(180)} 640 ${L(170)} 700 ${L(150)} 776`, `M${L(-160)} 34 C${L(-100)} 200 ${L(-170)} 380 ${L(-110)} 560 C${L(-90)} 640 ${L(-120)} 720 ${L(-100)} 776`, `M${L(160)} 52 C${L(120)} 160 ${L(160)} 260 ${L(100)} 360`], rim: [`M${L(-560)} 70 C${L(-300)} 30 ${L(-40)} 40 ${L(-40)} 40 C${L(160)} 50 ${L(330)} 120 ${L(430)} 215 C${L(510)} 285 ${L(615)} 318 ${L(612)} 366`] })}
  ${pads}${bag}${rooSvg}${rain}${fog ? `<g>${fog}</g>` : ""}
  </svg>`;
}
