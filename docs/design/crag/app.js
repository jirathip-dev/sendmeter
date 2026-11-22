const q = new URLSearchParams(location.search);
const S = q.get("s") || "today";
const M = q.get("m") || "night";
const W = innerWidth, H = innerHeight;
const WIDE = W > 700;
document.documentElement.dataset.mode = M;
const LIGHT = ["day", "golden", "fog"].includes(M);
const css = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();

const ICON = {
  today: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 19 9 8l4 6 3-4 6 9z"/><circle cx="17" cy="5" r="2"/></svg>`,
  session: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8.4 7.2C7 5.6 6.4 2.6 7.2 1.6c1.2.4 2.4 3 2.6 5zM15.6 7.2c1.4-1.6 2-4.6 1.2-5.6-1.2.4-2.4 3-2.6 5z"/><ellipse cx="12" cy="9.6" rx="5" ry="4.4"/><ellipse cx="12" cy="17.4" rx="4.6" ry="5"/><ellipse cx="9" cy="22.6" rx="3" ry="1.3"/><ellipse cx="15" cy="22.6" rx="3" ry="1.3"/><path d="M15.8 19.6c3 .4 5.6-.4 6-3.4.1-.8-1-.9-1.1-.1-.3 1.9-2 2.4-4.6 2z"/></svg>`,
  board: `<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="5" r="2.3"/><circle cx="12" cy="5" r="2.3"/><circle cx="19" cy="5" r="2.3"/><circle cx="5" cy="12" r="2.3"/><circle cx="12" cy="12" r="2.3"/><circle cx="19" cy="12" r="2.3"/><circle cx="5" cy="19" r="2.3"/><circle cx="12" cy="19" r="2.3"/><circle cx="19" cy="19" r="2.3"/></svg>`,
  force: `<svg viewBox="0 0 24 24" fill="currentColor"><rect x="2" y="1" width="20" height="2.4" rx="1.2"/><path d="M8.6 12.4 6.6 3.4h2.2l1.8 7.8zM15.4 12.4l2-9h-2.2l-1.8 7.8z"/><path d="M9.6 10.2 8.8 6.6l2 2.6zM14.4 10.2l.8-3.6-2 2.6z"/><ellipse cx="12" cy="11.4" rx="4" ry="3.5"/><ellipse cx="12" cy="17.4" rx="3.6" ry="4"/><ellipse cx="10.4" cy="22.2" rx="1.5" ry="1.6"/><ellipse cx="13.6" cy="22.2" rx="1.5" ry="1.6"/><path d="M15 19.6c2.4.8 3.8 2.2 4 3.8l-1.3.3c-.4-1.4-1.4-2.3-3-2.9z"/></svg>`,
  log: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M5 3.5h12.5v17H6.5A1.5 1.5 0 0 1 5 19z"/><path d="M5 17.5h12.5M8.5 3.5v14"/></svg>`,
  settings: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3.2"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/></svg>`,
  play: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 4.5v15a1 1 0 0 0 1.5.9l12-7.5a1 1 0 0 0 0-1.8l-12-7.5A1 1 0 0 0 7 4.5z"/></svg>`,
  bulb: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/></svg>`,
  check: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 12.5 5 5L20 6.5"/></svg>`,
  plus: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>`,
  search: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m20 20-4.8-4.8"/></svg>`,
  photo: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="3"/><circle cx="9" cy="10" r="1.8"/><path d="m4 18 6-5 4 3 3-2 4 3"/></svg>`,
  cloud: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M7 18h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.3 9.2 4.5 4.5 0 0 0 7 18z"/></svg>`,
  file: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/></svg>`,
  bt: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m7 7 10 10-5 4V3l5 4L7 17"/></svg>`,
};
const TABS = ["today", "session", "board", "force", "log"];
const cap = (k) => k[0].toUpperCase() + k.slice(1);

const P = (cx, cy, r, deg) => [cx + r * Math.cos((deg * Math.PI) / 180), cy + r * Math.sin((deg * Math.PI) / 180)];
const arc = (cx, cy, r, a0, a1) => {
  const [x0, y0] = P(cx, cy, r, a0), [x1, y1] = P(cx, cy, r, a1);
  return `M${x0.toFixed(1)} ${y0.toFixed(1)} A${r} ${r} 0 ${a1 - a0 > 180 ? 1 : 0} 1 ${x1.toFixed(1)} ${y1.toFixed(1)}`;
};
const card = (body, extra = "") => `<div class="glass card" ${extra}>${body}</div>`;
const hd = (h, right = "") => `<div class="row" style="margin-bottom:10px"><span class="h">${h}</span><span class="sp"></span>${right ? `<span class="mute small">${right}</span>` : ""}</div>`;
const list = (rows) => `<div class="list">${rows.map((r) => `<div>${r}</div>`).join("")}</div>`;
const tiles = (items, n = items.length) => `<div class="tiles" style="--n:${n}">${items.map(([v, k]) => `<div><b>${v}</b><small>${k}</small></div>`).join("")}</div>`;
const mascot = (pose, size, opts) => rooSvg(pose, size, opts);

function chip() {
  return `<div class="chip glass"><div class="crag">Pine Gully<small>Send conditions</small></div>
    <span class="v"><em>temp</em>14°</span><span class="v"><em>hum</em>52%</span>
    <span class="fr"><span>Friction</span>78</span></div>`;
}

function moonGauge(v, size) {
  const r = 70, cx = 100, cy = 92, lit = v / 100;
  const k = Math.cos(Math.PI * lit) * r;
  const d = `M${cx} ${cy - r} A${r} ${r} 0 0 1 ${cx} ${cy + r} A${Math.abs(k)} ${r} 0 0 ${lit > 0.5 ? 1 : 0} ${cx} ${cy - r}Z`;
  const ink = css("--ink"), acc = css("--accent-ink");
  const phase = (f, x) => { const kk = Math.cos(Math.PI * f) * 9; return `<g transform="translate(${x} 196)"><circle r="9" fill="${css("--moon-dark")}" stroke="${css("--track")}"/><path d="M0 -9 A9 9 0 0 1 0 9 A${Math.abs(kk)} 9 0 0 ${f > 0.5 ? 1 : 0} 0 -9Z" fill="${css("--moon-lit")}"/></g>`; };
  const zone = v >= 75 ? "SEND" : v >= 40 ? "TRAIN" : "REST";
  return `<svg class="gauge" viewBox="0 0 200 232" width="${size * 0.7}" height="${size * 0.81}" role="img" aria-label="Ready ${v}, ${zone}">
    <defs><radialGradient id="mg"><stop offset=".55" stop-color="${css("--glow")}"/><stop offset="1" stop-color="rgba(255,169,77,0)"/></radialGradient></defs>
    <circle cx="${cx}" cy="${cy}" r="${r + 26}" fill="url(#mg)"/>
    <circle cx="${cx}" cy="${cy}" r="${r}" fill="${css("--moon-dark")}"/>
    <path d="${d}" fill="${css("--moon-lit")}"/>
    <circle cx="${cx + 30}" cy="${cy - 34}" r="8" fill="#000" opacity=".07"/><circle cx="${cx + 46}" cy="${cy + 30}" r="6" fill="#000" opacity=".07"/><circle cx="${cx - 14}" cy="${cy + 44}" r="5" fill="#000" opacity=".07"/>
    <text x="${cx + 6}" y="${cy + 16}" text-anchor="middle" font-family="Barlow Condensed" font-weight="800" font-size="48" fill="${css("--moon-num")}">${v}</text>
    ${phase(0.25, 40)}${phase(0.6, 100)}${phase(1, 160)}
    ${[["REST", 40], ["TRAIN", 100], ["SEND", 160]].map(([t, x]) => `<text x="${x}" y="226" text-anchor="middle" font-family="Barlow Condensed" font-weight="800" font-size="13" letter-spacing="1" fill="${t === zone ? acc : ink}" opacity="${t === zone ? 1 : 0.75}">${t}</text>`).join("")}
  </svg>`;
}

function dial(label, val, sub, f, size = 54) {
  const cx = 28, cy = 28, r = 21, a = 135 + f * 270;
  const [nx, ny] = P(cx, cy, r - 5, a);
  return `<div class="dial"><svg viewBox="0 0 56 56" width="${size}" height="${size}">
    <path d="${arc(cx, cy, r, 135, 405)}" fill="none" stroke="${css("--track")}" stroke-width="6" stroke-linecap="round"/>
    <path d="${arc(cx, cy, r, 135, a)}" fill="none" stroke="${css("--accent")}" stroke-width="6" stroke-linecap="round"/>
    <line x1="${cx}" y1="${cy}" x2="${nx}" y2="${ny}" stroke="${css("--ink")}" stroke-width="3" stroke-linecap="round"/><circle cx="${cx}" cy="${cy}" r="4" fill="${css("--ink")}"/>
  </svg><div><small>${label}</small><b>${val}</b><span class="mute" style="font-size:12px">${sub}</span></div></div>`;
}

function meterCard(size) {
  return card(`${hd("Send-o-meter", "Sun 22 Nov")}
    <div class="meter">${moonGauge(82, size || (WIDE ? 270 : 196))}${dial("HRV", "64 ms", " +6", 0.72)}${dial("Sleep", "7h 40", " 92%", 0.86)}</div>`);
}

function weekCard() {
  const days = ["M", "T", "W", "T", "F", "S", "S"], on = [1, 1, 0, 1, 0, 1, 0];
  return card(`${hd("This week", "4 sessions · 12 sends")}<div class="row" style="justify-content:space-between;padding:2px 4px">${days.map((d, i) => `<div style="text-align:center"><div style="width:24px;height:24px;border-radius:50%;margin:0 auto 6px;${on[i] ? "background:var(--accent);box-shadow:0 0 14px var(--glow)" : "border:1.5px solid var(--track)"}"></div><span class="mute small">${d}</span></div>`).join("")}</div>`);
}

const TICKS = [["V5", "Moon Arete", "Pine Gully · today", "Flash", "on"], ["V4", "Slab Crack", "Pine Gully · today", "Send", "good"], ["6B+", "Warm-up 3", "Home board · Fri", "Send", "good"], ["V6", "Night Shift", "Pine Gully · 14 Nov", "Project", ""]];
const tickRow = ([g, n, s, t, c]) => `<span class="grade">${g}</span><span class="n">${n}<small>${s}</small></span><span class="sp"></span><span class="tag ${c}">${t}</span>`;
const ticksCard = (n = 3) => card(`${hd("Last ticks")}${list(TICKS.slice(0, n).map(tickRow))}`);
const startBtn = () => `<button class="btn" aria-label="Start session">${ICON.play}Start session</button>`;

function board(size, opts = {}) {
  const holds = opts.holds || { "1,9": "#43D17A", "3,10": "#43D17A", "2,7": "#4DA8FF", "4,6": "#4DA8FF", "3,4": "#4DA8FF", "5,3": "#4DA8FF", "6,1": "#FF5FB4", "7,8": "#FF9A3D", "5,10": "#FF9A3D" };
  const cols = opts.cols || 9, rows = opts.rows || 12, cell = size / cols;
  let g = "";
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    const c = holds[`${x},${y}`], cx = cell * (x + 0.5), cy = cell * (y + 0.5);
    g += c ? `<circle cx="${cx}" cy="${cy}" r="${cell * 0.38}" fill="${c}" opacity=".6" filter="url(#hg)"/><circle cx="${cx}" cy="${cy}" r="${cell * 0.26}" fill="none" stroke="${c}" stroke-width="3" ${opts.unsure === `${x},${y}` ? 'stroke-dasharray="4 3"' : ""}/><circle cx="${cx}" cy="${cy}" r="${cell * 0.1}" fill="#3A3F4D"/>`
      : `<circle cx="${cx}" cy="${cy}" r="${cell * 0.1}" fill="#3A3F4D"/>`;
  }
  const lab = opts.labels ? [...Array(cols)].map((_, x) => `<text x="${cell * (x + 0.5)}" y="${cell * rows + 12}" text-anchor="middle" font-family="Barlow" font-size="10" fill="#9AA0AE">${"ABCDEFGHIJK"[x]}</text>`).join("") : "";
  return `<svg viewBox="0 0 ${size} ${cell * rows + (opts.labels ? 16 : 0)}" width="100%" style="display:block;border-radius:18px;background:radial-gradient(ellipse 70% 60% at 50% 40%, #2A2E3A, #12151D)"><defs><filter id="hg" x="-2" y="-2" width="5" height="5"><feGaussianBlur stdDeviation="7"/></filter></defs>${g}${lab}</svg>`;
}
const legend = () => `<div class="chips">${[["#43D17A", "Start"], ["#4DA8FF", "Hand"], ["#FF5FB4", "Finish"], ["#FF9A3D", "Foot"]].map(([c, t]) => `<span><i style="width:10px;height:10px;border-radius:50%;background:${c};box-shadow:0 0 8px ${c}"></i>${t}</span>`).join("")}</div>`;

function forceCurve(wd, ht) {
  const n = 70, pts = [];
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    const f = t < 0.08 ? (t / 0.08) * 46 : t < 0.86 ? 46 + 6.4 * Math.sin(Math.min(1, (t - 0.08) / 0.2) * Math.PI / 2) - Math.max(0, t - 0.28) * 9 + Math.sin(i * 0.45) * 0.35 : Math.max(0, 50 - (t - 0.86) / 0.14 * 50);
    pts.push([t, f]);
  }
  const L = 34, R = wd - 14, Tp = 24, B = ht - 26;
  const X = (t) => L + t * (R - L), Y = (f) => B - (f / 60) * (B - Tp);
  const d = pts.map(([t, f], i) => `${i ? "L" : "M"}${X(t).toFixed(1)} ${Y(f).toFixed(1)}`).join(" ");
  const pk = pts.reduce((a, b) => (b[1] > a[1] ? b : a));
  const ink = css("--ink"), acc = css("--accent");
  return `<svg viewBox="0 0 ${wd} ${ht}" width="100%" height="${ht}">
    <defs><linearGradient id="fc" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${acc}" stop-opacity=".35"/><stop offset="1" stop-color="${acc}" stop-opacity="0"/></linearGradient></defs>
    ${[0, 20, 40, 60].map((k) => `<text x="${L - 6}" y="${Y(k) + 4}" text-anchor="end" font-family="Barlow" font-size="11" fill="${ink}" opacity=".75">${k}</text><path d="M${L} ${Y(k)} H${R}" stroke="${ink}" opacity=".08"/>`).join("")}
    ${[0, 2, 4, 6, 8, 10].map((s) => `<text x="${X(s / 10)}" y="${ht - 8}" text-anchor="middle" font-family="Barlow" font-size="11" fill="${ink}" opacity=".75">${s}s</text>`).join("")}
    <path d="M${L} ${Y(50.6)} H${R}" stroke="${ink}" stroke-width="1.2" stroke-dasharray="5 4" opacity=".55"/>
    <text x="${R}" y="${Y(50.6) + 16}" text-anchor="end" font-family="Barlow" font-size="12" fill="${ink}" opacity=".8">best 50.6</text>
    <path d="${d} L${X(1)} ${B} L${L} ${B}Z" fill="url(#fc)"/>
    <path d="${d}" fill="none" stroke="${acc}" stroke-width="3" stroke-linejoin="round" style="filter:drop-shadow(0 0 6px ${acc})"/>
    <circle cx="${X(pk[0])}" cy="${Y(pk[1])}" r="7" fill="${acc}" stroke="${css("--on-accent")}" stroke-width="2"/>
  </svg>`;
}

function nav(active) {
  if (!WIDE) return `<nav class="tabbar glass">${TABS.map((k) => `<a class="${k === active ? "on" : ""}">${ICON[k]}${cap(k)}</a>`).join("")}</nav>`;
  return `<nav class="side glass"><div class="brand"><img src="icons/current.png" width="34" height="34" style="border-radius:9px">Sendmeter</div>${[...TABS, "settings"].map((k) => `<a class="${k === active ? "on" : ""}">${ICON[k]}${cap(k)}</a>`).join("")}<div class="foot mute small" style="padding:0 10px">${{ night: "Night", day: "Day", dawn: "Dawn", golden: "Golden hour", rain: "Rain", fog: "Fog" }[M]} · Automatic</div></nav>`;
}

function topBar(title, opts = {}) {
  if (opts.back) return `<div class="top"><span class="back">‹ ${opts.back}</span><span class="mid">${title}</span>${opts.act ? `<span class="act">${opts.act}</span>` : `<span style="width:60px"></span>`}</div>`;
  return `<div class="top"><span class="title">${title}</span><span class="sp"></span>${opts.right || ""}</div>`;
}

function layout(title, cols, opts = {}) {
  const head = title ? topBar(title, opts) : "";
  if (!WIDE) return `<div class="content" style="${opts.contentStyle || ""}">${head}${cols.flat().filter(Boolean).join("")}</div>`;
  return `<div class="main">${head}<div class="cols" style="grid-template-columns:${opts.tpl || cols.map(() => "1fr").join(" ")}">${cols.map((c) => `<div class="col">${c.filter(Boolean).join("")}</div>`).join("")}</div></div>`;
}

const SCREENS = {
  today() {
    if (!WIDE) return { html: `<div class="content">${chip()}<div style="flex:1"></div>${meterCard()}${startBtn()}${weekCard()}</div>`, tab: "today", dim: false };
    return { tab: "today", dim: false, html: `<div class="main" style="left:auto;width:440px">${chip()}${meterCard()}${startBtn()}${weekCard()}${ticksCard()}</div>` };
  },
  conditions() {
    const bars = [...Array(30)].map((_, i) => 40 + Math.round(30 * Math.sin(i * 0.7) * Math.cos(i * 0.23) + (i % 7) * 3));
    bars[29] = 78;
    const ink = css("--ink");
    const chart = `<svg viewBox="0 0 300 96" width="100%" height="${WIDE ? 130 : 96}">${bars.map((b, i) => `<rect x="${i * 10 + 1}" y="${86 - b * 0.8}" width="7" height="${b * 0.8}" rx="3.5" fill="${i === 29 ? css("--accent") : ink}" opacity="${i === 29 ? 1 : 0.28}"/>`).join("")}<path d="M0 ${86 - 61 * 0.8} H300" stroke="${ink}" stroke-dasharray="4 4" opacity=".6"/><text x="2" y="${86 - 61 * 0.8 - 5}" font-family="Barlow" font-size="11" fill="${ink}">30-day average 61</text></svg>`;
    const sheet = `<div class="sheet glass">
      <div class="row"><div><div class="h">Send conditions</div><div style="font:700 22px var(--f-body)">Pine Gully</div></div><span class="sp"></span><span class="num" style="font-size:54px">78</span></div>
      <div class="row"><span class="tag good">Good friction</span><span class="sp"></span><span class="mute small">Better than 24 of the last 30 days</span></div>
      ${tiles([["14°", "Temp"], ["52%", "Humidity"], ["4°", "Dew point"], ["9 km/h", "Wind"]], 4)}
      <div class="h">Last 30 days</div>${chart}
      <div class="row mute small"><span>Best window today 17:00–20:00</span><span class="sp"></span><span>Open-Meteo</span></div></div>`;
    return { tab: "today", dim: true, html: SCREENS.today().html.replace('class="content"', 'class="content" style="opacity:.35"').replace('class="main"', 'class="main" style="opacity:.35;left:auto;width:440px"') + `<div class="scrim"></div>` + sheet };
  },
  session() {
    const live = card(`<div class="row"><div><div class="h">Session · Pine Gully</div><div class="num" style="font-size:52px;margin-top:4px">0:42:10</div></div><span class="sp"></span>${mascot("chalk", WIDE ? 96 : 74, { hand: "headlamp" })}</div>
      ${tiles([["14", "Tries"], ["5", "Sends"], ["V5", "Top"], ["128", "Heart"]], 4)}`);
    const now = card(`${hd("On now")}<div class="row"><span class="grade" style="font-size:28px">V6</span><span class="n" style="font:700 18px var(--f-body)">Night Shift<small class="mute" style="display:block;font:400 13px var(--f-body)">Try 4 · project</small></span></div>
      <div class="btns" style="margin-top:14px"><button class="btn">${ICON.check}Sent</button><button class="btn ghost">Fell</button></div>`);
    const tries = card(`${hd("This session", "14 tries")}${list([["V5", "Moon Arete", "1 try", "Flash", "on"], ["V4", "Slab Crack", "2 tries", "Send", "good"], ["V6", "Night Shift", "3 tries", "Project", ""], ["V3", "Warm-up Wall", "1 try", "Flash", "on"]].map(tickRow))}`);
    const end = `<button class="btn ghost">End session</button>`;
    return { tab: "session", html: layout("Session", [[live, now, WIDE ? end : null], [tries, WIDE ? null : end]], { tpl: "1fr 1fr" }) };
  },
  board() {
    const head = card(`<div class="row"><div style="width:44px;height:44px;border-radius:14px;background:var(--fill-on);display:grid;place-items:center;color:var(--accent-ink)">${ICON.board}</div><div class="n" style="font:700 17px var(--f-body)">Home wall<small class="mute" style="display:block;font:400 13px var(--f-body)">MoonBoard 2016 · 40°</small></div><span class="sp"></span><span class="tag good">Connected</span></div>`);
    const filt = `<div class="field">${ICON.search.replace("<svg", '<svg width="18" height="18"')}Search routes</div><div class="chips"><span class="on">V4–V6</span><span>Not sent</span><span>Mine</span><span>Benchmarks</span></div>`;
    const rows = [["V5", "Moon Arete", "Mine · 3 sends", "★★★", "Sent", "good"], ["V6", "Night Shift", "Mine · 0 sends", "★★", "Project", ""], ["V4", "Warm-up 3", "Imported · 12 sends", "★★", "Sent", "good"], ["V5", "Crimp Ladder", "Mine · 1 send", "★★★", "Flash", "on"], ["V6", "Left Hand Only", "Imported · 0 sends", "★", "", ""], ["V4", "Pinch Party", "Mine · 4 sends", "★★", "Sent", "good"]];
    const lst = card(`${hd("Routes", "128")}${list(rows.slice(0, WIDE ? 6 : 4).map(([g, n, s, st, t, c]) => `<span class="grade">${g}</span><span class="n">${n}<small>${s}</small></span><span class="sp"></span><span class="acc small">${st}</span>${t ? `<span class="tag ${c}">${t}</span>` : ""}`))}`);
    const add = `<div class="btns"><button class="btn sm">${ICON.plus}New route</button><button class="btn sm ghost">${ICON.photo}From screenshot</button></div>`;
    return { tab: "board", html: layout("Board", [[head, filt, lst], WIDE ? [add, card(`${hd("Board")}${list([["Lights", "Connected · 98%"], ["Angle", "40°"], ["Wiring check", "Passed 12 Nov"], ["Import routes", "From a file"]].map(([a, b]) => `<span class="n">${a}</span><span class="sp"></span><span class="val">${b}</span><span class="chev">›</span>`))}`)] : [add]], { tpl: "1.4fr 1fr", right: WIDE ? "" : `<span class="icon-btn" style="background:var(--fill)">${ICON.plus}</span>` }) };
  },
  route() {
    const info = card(`<div class="row"><span class="grade" style="font-size:30px">V5</span><div class="n" style="font:700 20px var(--f-body)">Moon Arete<small class="mute" style="display:block;font:400 13px var(--f-body)">Home wall · 40° · ★★★</small></div><span class="sp"></span><span class="tag on">Flash</span></div>`);
    const bd = card(board(WIDE ? 380 : 330) + `<div style="margin-top:12px">${legend()}</div>`);
    const btns = `<div class="btns"><button class="btn ghost">${ICON.bulb}Light it</button><button class="btn">${ICON.check}Log send</button></div>`;
    const tries = card(`${hd("Your ticks")}${list([["Flash", "Fri 20 Nov · 1 try"], ["Send", "Tue 10 Nov · 3 tries"]].map(([a, b]) => `<span class="n">${a}<small>${b}</small></span>`))}`);
    return { tab: "board", html: layout(WIDE ? "Moon Arete" : "", [[WIDE ? null : topBar("Route", { back: "Board", act: "Edit" }), WIDE ? null : info, bd], WIDE ? [info, btns, tries] : [btns]], { tpl: "minmax(0,440px) 1fr" }) };
  },
  send() {
    const base = SCREENS.route().html;
    const sheet = `<div class="sheet glass" style="align-items:center;text-align:center">
      <div style="margin-top:6px">${mascot("flash", WIDE ? 170 : 140)}</div>
      <div class="moment"><span class="big" style="font-size:46px">Flashed!</span></div>
      <div style="font:600 17px var(--f-body)">Moon Arete · V5</div><div class="mute small">First try · your 6th V5</div>
      <div style="width:100%">${tiles([["1", "Try"], ["6", "Sends today"], ["V5", "Top grade"]], 3)}</div>
      <div class="btns" style="width:100%"><button class="btn ghost">Undo</button><button class="btn">Done</button></div></div>`;
    return { tab: "board", html: base + `<div class="scrim"></div>` + sheet };
  },
  force() {
    const dev = card(`<div class="row"><span class="acc">${ICON.bt.replace("<svg", '<svg width="20" height="20"')}</span><span class="n">Force gauge<small>Connected · battery 98%</small></span><span class="sp"></span><span class="tag good">Live</span></div>`);
    const mode = `<div class="seg"><span class="on">Max hang</span><span>Repeaters</span><span>Pull</span></div>`;
    const live = card(`<div class="row"><div><div class="h">Peak · 20 mm edge · left</div><div class="num" style="font-size:64px;margin-top:6px">52.4<span style="font-size:26px"> kg</span></div></div><span class="sp"></span>
      <div style="text-align:center">${mascot("pr", WIDE ? 110 : 84)}<div class="moment" style="justify-content:center"><span class="big" style="font-size:28px">PR!</span></div></div></div>
      ${forceCurve(WIDE ? 640 : 330, WIDE ? 220 : 170)}${tiles([["52.4", "Peak kg"], ["48.1", "Avg kg"], ["8.6 s", "Time"]], 3)}`);
    const hist = card(`${hd("Last 6 weeks", "20 mm · left")}${list([["52.4 kg", "Today", "PR", "on"], ["50.6 kg", "15 Nov", "", ""], ["49.8 kg", "8 Nov", "", ""], ["48.2 kg", "1 Nov", "", ""]].map(([a, b, t, c]) => `<span class="n">${a}<small>${b}</small></span><span class="sp"></span>${t ? `<span class="tag ${c}">${t}</span>` : ""}`))}`);
    return { tab: "force", html: layout("Force", [[WIDE ? null : mode, live], [WIDE ? mode : null, dev, WIDE ? hist : null, `<button class="btn">${ICON.play}Start hang</button>`]], { tpl: "1.6fr 1fr" }) };
  },
  log() {
    const st = card(`${hd("November", "‹ ›")}${tiles([["14", "Sessions"], ["63", "Sends"], ["V6", "Top"]], 3)}`);
    const grades = [["V6", 2, 6], ["V5", 9, 14], ["V4", 18, 21], ["V3", 22, 24], ["V2", 12, 12]];
    const pyr = card(`${hd("Grades", "sends / tries")}${grades.map(([g, s, t]) => `<div class="row" style="margin:7px 0"><span class="grade" style="font-size:16px;min-width:30px">${g}</span><div style="flex:1;height:14px;border-radius:7px;background:var(--fill);position:relative"><div style="position:absolute;inset:0 auto 0 0;width:${(t / 24) * 100}%;border-radius:7px;background:var(--track)"></div><div style="position:absolute;inset:0 auto 0 0;width:${(s / 24) * 100}%;border-radius:7px;background:var(--accent);box-shadow:0 0 10px var(--glow)"></div></div><span class="mute small" style="min-width:44px;text-align:right">${s}/${t}</span></div>`).join("")}`);
    const cal = card(`${hd("Days")}<div style="display:grid;grid-template-columns:repeat(7,1fr);gap:6px">${[...Array(30)].map((_, i) => { const v = [0, 2, 0, 3, 0, 1, 0][i % 7] * ((i * 7) % 5 ? 1 : 0); return `<div style="aspect-ratio:1;border-radius:50%;background:${v ? "var(--accent)" : "var(--fill)"};opacity:${v ? 0.35 + v * 0.22 : 1}"></div>`; }).join("")}</div>`);
    const sess = card(`${hd("Sessions")}${list([["Sun 22", "Pine Gully · 0:42", "5 sends"], ["Fri 20", "Home wall · 1:10", "8 sends"], ["Wed 18", "Pine Gully · 2:05", "11 sends"]].map(([a, b, c]) => `<span class="n">${a}<small>${b}</small></span><span class="sp"></span><span class="val">${c}</span><span class="chev">›</span>`))}`);
    return { tab: "log", html: layout("Log", [[st, pyr], [cal, sess]], { right: `<span class="act acc">Logbook ›</span>` }) };
  },
  logbook() {
    const seg = `<div class="seg"><span class="on">All</span><span>Sends</span><span>Projects</span></div>`;
    const grp = (d, rows) => card(`${hd(d)}${list(rows.map(tickRow))}`);
    return { tab: "log", html: layout(WIDE ? "Logbook" : "", [[WIDE ? null : topBar("Logbook", { back: "Log" }), seg, grp("Today", TICKS.slice(0, 2)), grp("Fri 20 Nov", [TICKS[2], ["V5", "Crimp Ladder", "Home wall", "Flash", "on"]])], WIDE ? [grp("Sat 14 Nov", [TICKS[3], ["V4", "Pocket Rocket", "Pine Gully", "Send", "good"], ["V3", "Warm-up Wall", "Pine Gully", "Flash", "on"]])] : [grp("Sat 14 Nov", [TICKS[3]])]], { tpl: "1fr 1fr" }) };
  },
  settings() {
    const row = (a, b, extra = "") => `<span class="n">${a}</span><span class="sp"></span>${b ? `<span class="val">${b}</span>` : ""}${extra || '<span class="chev">›</span>'}`;
    const scene = card(`${hd("Scene")}${list([row("Automatic", "", '<span class="toggle on"></span>')])}<div class="mute small" style="margin:4px 0 8px">Or pin one</div><div class="chips">${["Day", "Night", "Dawn", "Golden hour", "Rain", "Fog"].map((k) => `<span>${k}</span>`).join("")}</div>
      <div class="list" style="margin-top:8px"><div>${row("Loading screen", "Headlamp")}</div><div><span class="n">Iridescent<small>Unlocks at 100 sends · 63 so far</small></span><span class="sp"></span><span class="tag">Locked</span></div></div>`);
    const look = card(`${hd("Look")}${list([`<img src="icons/current.png" width="40" height="40" style="border-radius:10px"><span class="n">App icon<small>Original</small></span><span class="sp"></span><span class="chev">›</span>`, row("Units", "kg · °C")])}`);
    const data = card(`${hd("Data")}${list([row("Apple Health", "On"), row("iCloud sync", "Off"), row("Bring over old data", ""), row("Boards", "1")])}`);
    const acct = card(`${hd("Account")}${list([row("Signed in", "Apple"), row("Help", "")])}`);
    return { tab: "settings", html: layout("Settings", [[scene, look], [data, acct]]) };
  },
  appicon() {
    const sets = iconSets();
    const grp = (h, items, sz) => card(`${hd(h, items.length + "")}<div style="display:grid;grid-template-columns:repeat(${WIDE ? (items.length > 6 ? 8 : 6) : 4},1fr);gap:${WIDE ? 16 : 12}px 10px">${items.map(([html, name, on]) => `<div style="text-align:center"><div style="display:inline-block;border-radius:${sz * 0.225 + 3}px;padding:3px;${on ? "box-shadow:0 0 0 2.5px var(--accent)" : ""}">${html}</div><div class="small ${on ? "acc" : "mute"}" style="margin-top:4px">${name}</div></div>`).join("")}</div>`);
    const sz = WIDE ? 84 : 62;
    return { tab: "settings", html: layout(WIDE ? "App icon" : "", [[WIDE ? null : topBar("App icon", { back: "Settings" }), grp("Original", [[iconImg(sets.original, sz), "Original", true]], sz), grp("Weather", sets.weather.map(([k, n]) => [stateIcon(k, sz), n]), sz), grp("Sticker", sets.sticker.map(([k, n]) => [stickerIcon(k, sz), n]), sz)]], { tpl: "1fr" }) };
  },
  pick() {
    const walls = `<div class="chips"><span class="on">Home wall · 2016</span><span>Gym · Mini 2020</span></div>`;
    const guide = card(`${hd("A good screenshot")}<div class="row" style="gap:14px"><div style="width:${WIDE ? 120 : 90}px">${board(WIDE ? 120 : 90, { cols: 11, rows: 18, holds: { "2,16": "#43D17A", "4,12": "#4DA8FF", "6,8": "#4DA8FF", "5,4": "#4DA8FF", "7,0": "#FF5FB4" } })}</div><div class="mute small" style="display:flex;flex-direction:column;gap:6px"><span>${ICON.check.replace("<svg", '<svg width="14" height="14"')} Whole board in view</span><span>${ICON.check.replace("<svg", '<svg width="14" height="14"')} A–K and 1–18 showing</span><span>${ICON.check.replace("<svg", '<svg width="14" height="14"')} Holds circled</span></div></div>`);
    const btns = `<button class="btn">${ICON.photo}Choose screenshot</button><button class="btn ghost">Paste</button><div class="mute small" style="text-align:center">Read on this phone</div>`;
    return { tab: "board", html: layout(WIDE ? "Route from screenshot" : "", [[WIDE ? null : topBar("From screenshot", { back: "Board" }), card(`${hd("Wall")}${walls}`), guide], [btns]].map((c, i) => (WIDE ? c : c)), { tpl: "1.2fr 1fr" }) };
  },
  check() {
    const holds = { "2,16": "#43D17A", "3,15": "#43D17A", "4,12": "#4DA8FF", "6,10": "#4DA8FF", "5,7": "#4DA8FF", "7,4": "#4DA8FF", "6,0": "#FF5FB4" };
    const bd = card(`<div class="row" style="margin-bottom:10px"><span class="h">Holds read</span><span class="sp"></span><span class="tag warn">1 to check</span></div>${board(WIDE ? 360 : 330, { cols: 11, rows: 18, holds, unsure: "7,4", labels: true })}`);
    const roles = `<div class="seg"><span class="on">Start</span><span>Hand</span><span>Finish</span><span>Erase</span></div>`;
    const meta = card(`${list([`<span class="n">Name</span><span class="sp"></span><span class="val">Route 22 Nov</span>`, `<span class="n">Grade</span><span class="sp"></span><span class="val">Optional</span>`])}`);
    const shot = WIDE ? card(`${hd("Your screenshot")}<div style="border-radius:16px;overflow:hidden;opacity:.9">${board(300, { cols: 11, rows: 18, holds })}</div>`) : null;
    return { tab: "board", html: layout(WIDE ? "Check holds" : "", [[WIDE ? null : topBar("Check holds", { back: "Back", act: "Save" }), bd], [roles, meta, shot, `<button class="btn">Save</button>`]], { tpl: "minmax(0,420px) 1fr" }) };
  },
  cantread() {
    const box = card(`<div class="empty">${mascot("fall", WIDE ? 120 : 100)}<div class="big">Can't read this one</div><div class="mute">Not a MoonBoard. No A–K, 1–18 grid found.</div><div class="mute small">Nothing saved</div></div>`);
    return { tab: "board", html: layout(WIDE ? "" : "", [[WIDE ? null : topBar("From screenshot", { back: "Board" }), box, `<button class="btn">${ICON.photo}Choose another</button>`, `<button class="btn plain">Mark holds by hand</button>`]], { contentStyle: "justify-content:center" }), flow: true };
  },
  boardsetup() {
    const kinds = card(`${hd("Board")}${list([["MoonBoard", "2016 · 2019 · 2024 · Mini"], ["Tension", "TB2 · Spray · Mirror"], ["Kilter", "Original · Homewall"], ["My own wall", "Draw the grid"]].map(([a, b], i) => `<span class="n">${a}<small>${b}</small></span><span class="sp"></span>${i === 0 ? `<span class="acc">${ICON.check.replace("<svg", '<svg width="20" height="20"')}</span>` : ""}`))}`);
    const opts = card(`${hd("Layout")}<div class="chips" style="margin-bottom:12px"><span>2016</span><span class="on">2019</span><span>2024</span><span>Mini 2020</span></div>${hd("Angle")}<div class="chips"><span>25°</span><span class="on">40°</span></div>`);
    const name = `<div class="field" style="color:var(--ink)">Home wall</div>`;
    return { tab: "board", html: layout(WIDE ? "Set up your board" : "", [[WIDE ? null : topBar("Set up board", { back: "Board" }), kinds], [name, opts, `<button class="btn">Next: wiring check</button>`]], { tpl: "1fr 1fr" }) };
  },
  wiring() {
    const holds = {};
    for (let y = 0; y < 18; y++) for (let x = 0; x < 11; x++) if ((x + y) % 2 === 0 && !(x === 7 && y === 5)) holds[`${x},${y}`] = y < 6 ? "#FF5FB4" : y < 12 ? "#4DA8FF" : "#43D17A";
    const bd = card(`<div class="row" style="margin-bottom:10px"><span class="h">Step 2 of 3 · Rows lit</span><span class="sp"></span><span class="tag good">Connected</span></div>${board(WIDE ? 340 : 300, { cols: 11, rows: 18, holds, labels: true })}`);
    const ask = card(`<div style="font:700 19px var(--f-body);margin-bottom:6px">Do the lit holds on your wall match?</div><div class="mute small" style="margin-bottom:12px">Top pink, middle blue, bottom green.</div><div class="btns"><button class="btn">${ICON.check}They match</button><button class="btn ghost">Some don't</button></div>`);
    return { tab: "board", html: layout(WIDE ? "Wiring check" : "", [[WIDE ? null : topBar("Wiring check", { back: "Back" }), bd], [ask, card(list([["1", "Light one corner", "Passed"], ["2", "Rows lit", "Now"], ["3", "Every hold", ""]].map(([n, a, b]) => `<span class="grade" style="font-size:18px;min-width:22px">${n}</span><span class="n">${a}</span><span class="sp"></span>${b ? `<span class="tag ${b === "Passed" ? "good" : "on"}">${b}</span>` : ""}`)))]], { tpl: "minmax(0,400px) 1fr" }) };
  },
  boardimport() {
    const f = card(`<div class="row"><span class="acc">${ICON.file.replace("<svg", '<svg width="26" height="26"')}</span><span class="n">export.json<small>From your board maker · 2.1 MB</small></span></div>`);
    const prev = card(`${hd("Found")}${tiles([["412", "Sends"], ["37", "Your routes"], ["9", "Skipped"]], 3)}<div class="mute small" style="margin-top:10px">Skipped: holds not on your layout.</div>`);
    const into = card(`${hd("Into")}${list([`<span class="n">Home wall<small>MoonBoard 2019 · 40°</small></span><span class="sp"></span><span class="acc">${ICON.check.replace("<svg", '<svg width="20" height="20"')}</span>`])}`);
    return { tab: "board", html: layout(WIDE ? "Import routes" : "", [[WIDE ? null : topBar("Import", { back: "Board" }), f, prev], [into, `<button class="btn">Import 449</button>`, `<div class="mute small" style="text-align:center">Stays on this phone and your iCloud</div>`]], { tpl: "1fr 1fr" }) };
  },
  dataimport() {
    const bar = (p) => `<div style="height:12px;border-radius:6px;background:var(--fill);overflow:hidden"><div style="width:${p}%;height:100%;border-radius:6px;background:var(--accent);box-shadow:0 0 12px var(--glow)"></div></div>`;
    const prog = card(`<div class="empty" style="padding:10px 6px">${mascot("send", WIDE ? 120 : 96)}<div class="big">Bringing over your data</div><div class="mute small">From your old Sendmeter account</div></div>${bar(64)}<div class="row small" style="margin-top:8px"><span class="mute">Sessions</span><span class="sp"></span><span>412 of 640</span></div>`);
    const parts = card(list([["Sessions", "412 / 640", "on"], ["Ticks", "1,284", "good"], ["Force tests", "96", "good"], ["Health days", "Waiting", ""]].map(([a, b, c]) => `<span class="n">${a}</span><span class="sp"></span><span class="tag ${c}">${b}</span>`)));
    return { tab: "settings", html: layout(WIDE ? "Bring over old data" : "", [[WIDE ? null : topBar("Old data", { back: "Settings" }), prog], [parts, `<div class="mute small" style="text-align:center">Keep the app open. It picks up where it stopped.</div>`]], { tpl: "1fr 1fr" }) };
  },
  sync() {
    const t = card(list([`<span class="acc">${ICON.cloud.replace("<svg", '<svg width="24" height="24"')}</span><span class="n">Sync with iCloud<small>Your private iCloud only</small></span><span class="sp"></span><span class="toggle on"></span>`]));
    const st = card(`${hd("Status")}${list([["Last synced", "2 min ago"], ["This iPhone", "Up to date"], ["Apple Watch", "Up to date"], ["iPad", "3 changes waiting"]].map(([a, b]) => `<span class="n">${a}</span><span class="sp"></span><span class="val">${b}</span>`))}`);
    return { tab: "settings", html: layout(WIDE ? "iCloud sync" : "", [[WIDE ? null : topBar("iCloud sync", { back: "Settings" }), t, st]], { tpl: "minmax(0,560px)" }) };
  },
  empty() {
    const box = card(`<div class="empty">${mascot("rest", WIDE ? 150 : 120)}<div class="big">No sessions yet</div><div class="mute">Your sends land here.</div></div>`);
    return { tab: "log", html: layout("Log", [[box, startBtn()]], { tpl: "minmax(0,520px)" }) };
  },
  error() {
    const box = card(`<div class="empty">${mascot("fall", WIDE ? 140 : 110)}<div class="big">Whipper</div><div class="mute">Couldn't reach the force gauge.</div><div class="mute small">Check it's on and nearby.</div></div>`);
    return { tab: "force", html: layout("Force", [[box, `<button class="btn">Try again</button>`]], { tpl: "minmax(0,520px)" }) };
  },
  firstrun() {
    const hero = `<div style="text-align:center;margin-top:${WIDE ? 0 : 24}px"><div style="font:800 ${WIDE ? 64 : 48}px/1 var(--f-display);letter-spacing:.08em;text-transform:uppercase;color:var(--title)">Sendmeter</div><div style="font:600 17px var(--f-body);color:var(--title);margin-top:8px">Log every send. Watch yourself get stronger.</div></div>`;
    const steps = card(list([["Apple Health", "HRV, sleep and heart rate for the Send-o-meter", "Allow"], ["Location", "Weather and friction at your crag", "Allow"], ["Old account", "Bring over your sessions", "Sign in"]].map(([a, b, c]) => `<span class="n">${a}<small>${b}</small></span><span class="sp"></span><button class="btn sm ghost">${c}</button>`)));
    return { nav: false, dim: false, flow: true, html: WIDE ? `<div class="main">${hero}${steps}<button class="btn">Get started</button></div>` : `<div class="content" style="bottom:24px">${hero}<div style="flex:1"></div>${steps}<button class="btn">Get started</button></div>` };
  },
  loading() {
    return { nav: false, dim: false, loading: true, html: `<div style="position:absolute;left:0;right:0;top:${WIDE ? 70 : 96}px;text-align:center;z-index:3"><div style="font:800 ${WIDE ? 56 : 40}px/1 var(--f-display);letter-spacing:.1em;text-transform:uppercase;color:#FFF;text-shadow:0 0 24px rgba(255,169,77,.5)">Sendmeter</div></div>` };
  },
};

function iconImg(src, sz) { return `<img src="${src}" width="${sz}" height="${sz}" style="display:block;border-radius:${sz * 0.225}px">`; }

function iconSets() {
  return {
    original: "icons/current.png",
    weather: [["day", "Day"], ["night", "Night"], ["dawn", "Dawn"], ["golden", "Golden"], ["rain", "Rain"], ["fog", "Fog"]],
    sticker: [["dyno", "Dyno"], ["crimp", "Crimp"], ["chalk", "Chalk-up"], ["flash", "Flash"], ["send", "Send"], ["fall", "Fall"], ["rest", "Rest"], ["pr", "PR"]],
  };
}

const ICON_TINT = {
  day: ["linear-gradient(#7FB6E6, #CFE6F2 60%, #E9E4D6)", "color", 0.78, "sun"],
  night: ["linear-gradient(#0B1430, #1C2B50)", "color", 0.35, "moon"],
  dawn: ["linear-gradient(#3B3462, #C98A93 55%, #F5C69A)", "color", 0.7, "sunrise"],
  golden: ["linear-gradient(#E9A55A, #F3D08C 55%, #B8804B)", "color", 0.75, "sun"],
  rain: ["linear-gradient(#4B5866, #6E7C89)", "color", 0.7, "rain"],
  fog: ["linear-gradient(#B9C0C2, #DADDDA)", "color", 0.72, "fog"],
};

function stateIcon(k, sz) {
  const [grad, blend, a, sky] = ICON_TINT[k];
  const light = k === "day" || k === "golden" || k === "fog";
  let over = "";
  if (sky === "sun") over = `<div style="position:absolute;right:14%;top:9%;width:20%;height:20%;border-radius:50%;background:#FFF3C4;box-shadow:0 0 ${sz * 0.12}px ${sz * 0.06}px rgba(255,236,170,.8)"></div>`;
  if (sky === "sunrise") over = `<div style="position:absolute;right:10%;top:16%;width:22%;height:22%;border-radius:50%;background:#FFD9A8;box-shadow:0 0 ${sz * 0.14}px ${sz * 0.06}px rgba(255,190,140,.8)"></div>`;
  if (sky === "rain") over = `<div style="position:absolute;inset:0;background:repeating-linear-gradient(105deg, transparent 0 ${sz * 0.07}px, rgba(220,232,244,.55) ${sz * 0.07}px ${sz * 0.075}px);"></div>`;
  if (sky === "fog") over = `<div style="position:absolute;inset:0;background:linear-gradient(transparent 20%, rgba(236,238,236,.75) 55%, rgba(236,238,236,.35) 85%)"></div>`;
  return `<div style="position:relative;width:${sz}px;height:${sz}px;border-radius:${sz * 0.225}px;overflow:hidden;isolation:isolate">
    <img src="icons/current.png" width="${sz}" height="${sz}" style="display:block;${light ? "filter:brightness(1.9) contrast(.85)" : ""}">
    <div style="position:absolute;inset:0;background:${grad};mix-blend-mode:${blend};opacity:${a}"></div>
    ${light ? `<div style="position:absolute;inset:0;background:${grad};mix-blend-mode:multiply;opacity:.45"></div>` : ""}${over}</div>`;
}

const STICKER_BG = { dyno: "#1B2140", crimp: "#2B2350", chalk: "#1F3346", flash: "#3A2448", send: "#1E3A36", fall: "#3B2A2E", rest: "#22284A", pr: "#3A2E1E" };
function stickerIcon(k, sz) {
  const bg = STICKER_BG[k];
  return `<div style="width:${sz}px;height:${sz}px;border-radius:${sz * 0.225}px;overflow:hidden;background:radial-gradient(circle at 84% 14%, rgba(255,240,210,.3) 0 7%, transparent 7.5%), ${bg};display:grid;place-items:end center">
    ${rooSvg(k, sz * 0.74, { props: true })}</div>`;
}

function render() {
  if (S === "states") return (document.body.innerHTML = statesSheet());
  if (S === "mascots") return (document.body.innerHTML = mascotSheet());
  if (S === "watch") return (document.body.innerHTML = watchSheet());
  const sc = SCREENS[S]();
  const dim = sc.dim ?? true;
  const state = M;
  let bg = scene(state, W, H, { rooScale: WIDE ? 0.48 : 0.34, ground: !WIDE && !dim ? Math.round(H * 0.4) : undefined });
  if (sc.loading) bg = loadingDyno();
  const tab = sc.tab;
  document.body.innerHTML = `<div class="page ${WIDE ? "p1440" : "p390"} ${dim ? "dim" : ""} ${sc.nav === false ? "" : "tabbed"} ${sc.flow ? "flow" : ""}">
    <div class="bg">${bg}</div><div class="beam"></div>
    ${WIDE ? "" : `<div class="status" style="color:${LIGHT && !dim ? "#1F1A14" : LIGHT ? "#2A2118" : "#fff"}"><span>9:41</span><i></i></div>`}
    ${sc.html}${sc.nav === false ? "" : nav(tab === "settings" && !WIDE ? "today" : tab)}</div>`;
}

function loadingDyno() {
  const G = Math.round(H * (WIDE ? 0.56 : 0.47));
  let svg = scene("night", W, H, { pose: "sit", rooScale: 0.001 });
  const rs = WIDE ? 0.55 : 0.4;
  const x = W * (WIDE ? 0.5 : 0.52), y = G - (WIDE ? 380 : 300);
  const ghost = [[-150, 120, 0.18], [-80, 50, 0.3]].map(([dx, dy, o]) => `<g opacity="${o}" transform="translate(${x + dx * rs * 2 - 100 * rs} ${y + dy * rs * 2}) scale(${rs})">${roo("dyno", "headlamp", false)}</g>`).join("");
  const arcPath = `<path d="M${x - 330 * rs} ${y + 330 * rs} Q ${x - 80 * rs} ${y - 120 * rs} ${x + 60 * rs} ${y + 40 * rs}" fill="none" stroke="#FFC98A" stroke-width="3" stroke-dasharray="2 10" stroke-linecap="round" opacity=".7"/>`;
  const hero = `<g transform="translate(${x - 100 * rs} ${y}) scale(${rs})">${roo("dyno", "headlamp", false)}</g>`;
  return svg.replace("</svg>", `${arcPath}${ghost}${hero}</svg>`);
}

function statesSheet() {
  const states = [["day", "Day"], ["dawn", "Dawn"], ["golden", "Golden hour"], ["night", "Night"], ["rain", "Rain"], ["fog", "Fog"]];
  const fw = WIDE ? 216 : 170, fh = WIDE ? 468 : 368;
  return `<div class="sheetpage"><h1>Today in every state</h1><div class="grid" style="grid-template-columns:repeat(${WIDE ? 6 : 2},1fr)">${states.map(([k, n]) => `<figure><iframe src="index.html?s=today&m=${k}" width="390" height="844" style="border:0;border-radius:${WIDE ? 40 : 36}px;width:390px;height:844px;transform:scale(${fw / 390});transform-origin:0 0;margin-bottom:${fh - 844}px;margin-right:${fw - 390}px"></iframe><figcaption>${n}<small>${{ day: "Light cards, dark text", dawn: "Rose glass, low beam", golden: "Warm light cards", night: "Dark glass, headlamp beam", rain: "Slate glass, roo shelters", fog: "Mist-white cards" }[k]}</small></figcaption></figure>`).join("")}</div></div>`;
}

function mascotSheet() {
  const poses = [["sit", "Sit · tab, Today"], ["chalk", "Chalk-up · Today"], ["look", "Moon-watch · night"], ["shelter", "Shelter · rain"], ["dyno", "Dyno · loading"], ["crimp", "Crimp"], ["hang", "Hang · Force tab"], ["flash", "Flash · Flashed!"], ["send", "Send · Sent"], ["fall", "Fall · Whipper, errors"], ["rest", "Rest · empty, rest day"], ["pr", "PR · new best"]];
  const sz = WIDE ? 150 : 104;
  return `<div class="sheetpage"><h1>The roo · sticker style</h1><div class="grid" style="grid-template-columns:repeat(${WIDE ? 6 : 3},1fr);gap:${WIDE ? 22 : 14}px 10px">${poses.map(([p, n]) => `<figure style="align-items:center;text-align:center">${rooSvg(p, sz, { props: true, hand: p === "look" || p === "shelter" ? "headlamp" : "" })}<figcaption>${n.split(" · ")[0]}<small>${n.split(" · ")[1] || ""}</small></figcaption></figure>`).join("")}</div>
    <h2>Tab icons at 25 pt</h2><div class="row" style="gap:28px;color:var(--ink)">${TABS.map((k) => `<div style="text-align:center;${k === "session" ? "color:var(--accent-ink)" : ""}">${ICON[k].replace("<svg", '<svg width="25" height="25"')}<div class="small mute">${cap(k)}</div></div>`).join("")}</div></div>`;
}

function watchSheet() {
  const w = (inner) => `<div class="watch">${inner}</div>`;
  const ready = w(`<div class="wtop"><span>Ready</span><span>9:41</span></div><div style="display:grid;place-items:center;margin-top:-4px">${moonGauge(82, 150)}</div>`);
  const sess = w(`<div class="wtop"><span class="acc">0:42</span><span>9:41</span></div><div style="padding:0 6px"><div class="h">V6 · Night Shift</div><div class="mute small">Try 4</div></div><div class="row" style="gap:6px;padding:0 4px"><div style="flex:1;text-align:center"><b style="font:800 30px var(--f-display)">14</b><div class="mute small">tries</div></div><div style="flex:1;text-align:center"><b style="font:800 30px var(--f-display)">5</b><div class="mute small">sends</div></div></div><div class="wbtn" style="background:var(--accent);color:var(--on-accent);margin-top:auto">Sent</div><div class="wbtn" style="background:var(--fill);height:36px;font-size:15px">Fell</div>`);
  const force = w(`<div class="wtop"><span>Hang · L</span><span>9:41</span></div><div style="text-align:center"><div class="num" style="font-size:54px;margin-top:6px">48.2</div><div class="mute small">kg · 6.1 s</div></div><div style="padding:0 6px">${forceCurve(180, 80)}</div>`);
  const moment = w(`<div style="display:grid;place-items:center;flex:1">${rooSvg("flash", 104, { props: true })}<div class="moment"><span class="big" style="font-size:30px">Flashed!</span></div><div class="mute small">V5 · Moon Arete</div></div>`);
  const start = w(`<div class="wtop"><span>Sendmeter</span><span>9:41</span></div><div style="display:grid;place-items:center;flex:1">${rooSvg("chalk", 84, { props: true })}</div><div class="mute small" style="text-align:center">Pine Gully · friction 78</div><div class="wbtn" style="background:var(--accent);color:var(--on-accent)">Start session</div>`);
  const items = [[start, "Start", "Plain label; the roo chalks up"], [ready, "Send-o-meter", "The moon gauge, alone"], [sess, "Session", "Sent / Fell, big targets"], [force, "Force", "Live kg and curve"], [moment, "Flashed!", "The moment, 2 s"]];
  return `<div class="sheetpage"><h1>Apple Watch</h1><div class="grid" style="grid-template-columns:repeat(${WIDE ? 5 : 2},1fr);gap:30px 18px;${WIDE ? "" : "transform:scale(.8);transform-origin:0 0;width:125%"}">${items.map(([h, n, s]) => `<figure style="align-items:center;text-align:center">${h}<figcaption style="margin-top:12px">${n}<small>${s}</small></figcaption></figure>`).join("")}</div></div>`;
}

document.fonts.ready.then(render);
render();
