import { roo } from "./pack/roo.mjs";

const IRI = `<stop offset="0" stop-color="#C2A8FF"/><stop offset=".5" stop-color="#8FE6E0"/><stop offset="1" stop-color="#FFB3DC"/>`;
let gid = 0;
const el = (cls, html, tag) => {
  const d = document.createElement("div");
  d.className = `${cls} standin`;
  d.innerHTML = `<span class="tagbox">stand-in · ${tag}</span>${html}`;
  return d;
};

export function moonPath(cx, cy, r, lit) {
  const k = Math.cos(Math.PI * lit) * r;
  return `M${cx} ${cy - r} A${r} ${r} 0 0 1 ${cx} ${cy + r} A${Math.abs(k).toFixed(2)} ${r} 0 0 ${lit > 0.5 ? 1 : 0} ${cx} ${cy - r}Z`;
}

export function moonGauge(v, w) {
  const id = `g${gid++}`, r = 70, cx = 100, cy = 88, zone = v >= 75 ? "SEND" : v >= 40 ? "TRAIN" : "REST";
  const mark = (f, x, on) => `<g transform="translate(${x} 190)"><circle r="8" fill="#1A1E40" stroke="${on ? "#EEF0FA" : "rgba(238,240,250,.25)"}" stroke-width="${on ? 2 : 1}"/><path d="${moonPath(0, 0, 8, f)}" fill="${on ? "#EEF0FA" : "rgba(238,240,250,.45)"}"/></g>`;
  return `<svg viewBox="0 0 200 226" width="${w}" height="${(w * 226) / 200}" role="img" aria-label="Ready ${v}, ${zone}">
    <defs><linearGradient id="${id}" x1="0" y1="0" x2="1" y2="1">${IRI}</linearGradient></defs>
    <circle cx="${cx}" cy="${cy}" r="${r + 16}" fill="#B9A8FF" opacity=".08"/>
    <circle cx="${cx}" cy="${cy}" r="${r}" fill="#1A1E40" stroke="rgba(238,240,250,.16)"/>
    <path d="${moonPath(cx, cy, r, v / 100)}" fill="url(#${id})"/>
    <circle cx="${cx + 28}" cy="${cy - 30}" r="8" fill="#120F2E" opacity=".08"/><circle cx="${cx + 42}" cy="${cy + 28}" r="6" fill="#120F2E" opacity=".08"/>
    <text x="${cx + 8}" y="${cy + 16}" text-anchor="middle" font-family="Zilla Slab" font-weight="700" font-size="50" fill="#120F2E">${v}</text>
    ${mark(0.25, 40, zone === "REST")}${mark(0.6, 100, zone === "TRAIN")}${mark(1, 160, zone === "SEND")}
    ${[["REST", 40], ["TRAIN", 100], ["SEND", 160]].map(([t, x]) => `<text x="${x}" y="220" text-anchor="middle" font-family="Zilla Slab" font-weight="700" font-size="13" letter-spacing="1.2" fill="${t === zone ? "#EEF0FA" : "#B3B8D4"}">${t}</text>`).join("")}
  </svg>`;
}

export function smallMoon(f, s = 46) {
  return `<svg viewBox="0 0 56 56" width="${s}" height="${s}" aria-hidden="true"><circle cx="28" cy="28" r="22" fill="#1A1E40" stroke="rgba(238,240,250,.2)"/><path d="${moonPath(28, 28, 22, f)}" fill="#E4E2F6"/></svg>`;
}

export function holdBoard(o = {}) {
  const holds = o.holds || { "1,9": "#43D17A", "3,10": "#43D17A", "2,7": "#4DA8FF", "4,6": "#4DA8FF", "3,4": "#4DA8FF", "5,3": "#4DA8FF", "6,1": "#FF5FB4", "7,8": "#FF9A3D", "5,10": "#FF9A3D" };
  const cols = 9, rows = o.rows || 12, cell = 40;
  let g = "";
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    const c = holds[`${x},${y}`], cx = cell * (x + 0.5), cy = cell * (y + 0.5);
    g += c ? `<circle cx="${cx}" cy="${cy}" r="15" fill="${c}" opacity=".35"/><circle cx="${cx}" cy="${cy}" r="11" fill="none" stroke="${c}" stroke-width="3" ${o.unsure === `${x},${y}` ? 'stroke-dasharray="4 3"' : ""}/><circle cx="${cx}" cy="${cy}" r="4" fill="#3A3F5C"/>`
      : `<circle cx="${cx}" cy="${cy}" r="4" fill="#2E3250"/>`;
  }
  return `<svg viewBox="0 0 ${cols * cell} ${rows * cell}" width="100%" style="display:block;border-radius:16px;background:#0E1130">${g}</svg>`;
}

export function forceCurve(w = 340, h = 190) {
  const n = 70, pts = [];
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    pts.push([t, t < 0.08 ? (t / 0.08) * 46 : t < 0.86 ? 46 + 6.4 * Math.sin(Math.min(1, (t - 0.08) / 0.2) * Math.PI / 2) - Math.max(0, t - 0.28) * 9 + Math.sin(i * 0.45) * 0.35 : Math.max(0, 50 - ((t - 0.86) / 0.14) * 50)]);
  }
  const L = 30, R = w - 10, T = 16, B = h - 22, X = (t) => L + t * (R - L), Y = (f) => B - (f / 60) * (B - T);
  const d = pts.map(([t, f], i) => `${i ? "L" : "M"}${X(t).toFixed(1)} ${Y(f).toFixed(1)}`).join(" ");
  const pk = pts.reduce((a, b) => (b[1] > a[1] ? b : a));
  return `<svg viewBox="0 0 ${w} ${h}" width="100%" role="img" aria-label="Force curve, peak 52.4 kg">
    ${[0, 20, 40, 60].map((k) => `<text x="${L - 6}" y="${Y(k) + 4}" text-anchor="end" font-family="Inter" font-size="11" fill="#B3B8D4">${k}</text><path d="M${L} ${Y(k)}H${R}" stroke="rgba(238,240,250,.08)"/>`).join("")}
    ${[0, 5, 10].map((s) => `<text x="${X(s / 10)}" y="${h - 4}" text-anchor="middle" font-family="Inter" font-size="11" fill="#B3B8D4">${s}s</text>`).join("")}
    <path d="M${L} ${Y(50.6)}H${R}" stroke="#EEF0FA" stroke-dasharray="5 4" opacity=".5"/><text x="${R}" y="${Y(50.6) + 15}" text-anchor="end" font-family="Inter" font-size="12" fill="#B3B8D4">best 50.6</text>
    <path d="${d} L${X(1)} ${B} L${L} ${B}Z" fill="#B9A8FF" opacity=".14"/>
    <path d="${d}" fill="none" stroke="#B9A8FF" stroke-width="3" stroke-linejoin="round"/>
    <circle cx="${X(pk[0])}" cy="${Y(pk[1])}" r="6" fill="#EEF0FA"/>
  </svg>`;
}

const roodiv = (pose, size, flip) => `<div style="display:flex;justify-content:center">${roo(pose, { size, flip })}</div>`;

export const KINDS = {
  "crag-moon": (b) => el("b-app glass", `<div class="ch" style="display:flex;align-items:baseline"><b class="b-card__title">Send-o-meter</b><p class="m b-card__subtitle">${b.date}</p></div>
    <div class="gauge-wrap">${moonGauge(b.value, b.size || 190)}<div class="dials">
      <div class="dial">${smallMoon(b.hrv[2])}<div><small>HRV</small><b>${b.hrv[0]}</b><span>${b.hrv[1]}</span></div></div>
      <div class="dial">${smallMoon(b.sleep[2])}<div><small>SLEEP</small><b>${b.sleep[0]}</b><span>${b.sleep[1]}</span></div></div></div></div>`, "moon gauge"),
  "crag-board": (b) => el("b-app glass", holdBoard(b) + (b.legend ? `<div class="chips" style="margin-top:10px;justify-content:center">${[["#43D17A", "Start"], ["#4DA8FF", "Hand"], ["#FF5FB4", "Finish"], ["#FF9A3D", "Foot"]].map(([c, t]) => `<span style="display:inline-flex;align-items:center;gap:6px;font-size:13px;color:var(--mute)"><i style="width:10px;height:10px;border-radius:50%;background:${c}"></i>${t}</span>`).join("")}</div>` : ""), "hold board"),
  "crag-curve": (b) => el("b-app glass", `<div class="ch" style="display:flex"><b class="b-card__title">${b.title}</b><p class="m b-card__subtitle">${b.sub}</p></div>${forceCurve(b.w, b.h)}`, "plot (blocks staging lacks it)"),
  "crag-roo": (b) => el(`b-app ${b.glass === false ? "" : "glass"}`, `<div class="moment${b.row ? " row" : ""}">${roodiv(b.pose, b.size || 170, b.flip)}<div>${b.word ? `<h2 style="font-size:${b.wordSize || 54}px">${b.word}</h2>` : ""}${b.line ? `<p>${b.line}</p>` : ""}</div></div>`, "roo figure"),
  "crag-photo": (b) => el("b-app glass", `<div style="position:relative">${holdBoard({ ...b, rows: b.rows || 10 })}<div style="position:absolute;inset:0;border-radius:16px;background:linear-gradient(180deg,rgba(255,255,255,.05),rgba(0,0,0,.25));"></div>${b.boxes ? `<div style="position:absolute;left:8%;top:6%;right:8%;bottom:6%;border:2px dashed #B9A8FF;border-radius:12px"></div>` : ""}</div>`, "photo crop"),
};
