const q = new URLSearchParams(location.search);
const T = q.get("t") || "topo";
const S = q.get("s") || "today";
const W = innerWidth, H = innerHeight;
const WIDE = W > 700;
document.documentElement.dataset.t = T;

const SCENE_OF = { topo: "night", chalk: "golden", journal: "rain", headlamp: "night" };
const OTHER = { topo: "log", chalk: "session", journal: "force", headlamp: "route" };
const PAL = {
  topo: { line: "#DDE6EE", soft: "rgba(221,230,238,.35)", accent: "#F2B65A", rest: "#7C93AE", train: "#DDE6EE", send: "#F2B65A", ink: "#F3F5F7" },
  chalk: { line: "#F7F4EE", soft: "rgba(247,244,238,.3)", accent: "#E0553F", rest: "#8E8B86", train: "#E9E4DA", send: "#E0553F", ink: "#F7F4EE" },
  journal: { line: "#1D2B47", soft: "rgba(29,43,71,.3)", accent: "#2D5A3D", rest: "#8C97AA", train: "#1D2B47", send: "#2D5A3D", ink: "#1D2B47" },
  headlamp: { line: "#F5EDDF", soft: "rgba(245,237,223,.25)", accent: "#FFB547", rest: "#6F7A90", train: "#F5EDDF", send: "#FFB547", ink: "#F5EDDF" },
}[T];

const ICON = {
  today: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 19 9 8l4 6 3-4 6 9z"/><circle cx="17" cy="5" r="2"/></svg>`,
  session: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7.6 6 6.4.6l3.3 4.3zM14.4 6l1.2-5.4-3.3 4.3z"/><ellipse cx="11" cy="8.5" rx="4.6" ry="4.2"/><path d="M11 11c4.5 0 5.5 6 5 9-.4 2-2.5 2.6-5 2.6S6.4 22 6 20c-.5-3 .5-9 5-9z"/><ellipse cx="8" cy="22.4" rx="3.6" ry="1.4"/><ellipse cx="14" cy="22.4" rx="3.6" ry="1.4"/><path d="M15.5 20.5c3.5.5 7-.5 7.1-4.5 0-1-1.2-1-1.3 0-.3 2.6-2.3 3.4-5.5 3z"/></svg>`,
  board: `<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="5" r="2.3"/><circle cx="12" cy="5" r="2.3"/><circle cx="19" cy="5" r="2.3"/><circle cx="5" cy="12" r="2.3"/><circle cx="12" cy="12" r="2.3"/><circle cx="19" cy="12" r="2.3"/><circle cx="5" cy="19" r="2.3"/><circle cx="12" cy="19" r="2.3"/><circle cx="19" cy="19" r="2.3"/></svg>`,
  force: `<svg viewBox="0 0 24 24" fill="currentColor"><rect x="2" y="1" width="20" height="2.4" rx="1.2"/><path d="M7.2 12 6.4 3h2l1.2 8.5zM16.8 12l.8-9h-2l-1.2 8.5z"/><path d="M9.8 8.4 9.4 4l2 3.6zM14.2 8.4l.4-4.4-2 3.6z"/><ellipse cx="12" cy="10.5" rx="3.8" ry="3.5"/><path d="M12 13c3 0 3.8 4 3.4 6.4-.4 1.6-1.8 2-3.4 2s-3-.4-3.4-2C8.2 17 9 13 12 13z"/><ellipse cx="10" cy="22" rx="1.6" ry="1.8"/><ellipse cx="14" cy="22" rx="1.6" ry="1.8"/><path d="M14.6 19c2.4 1 3.8 2.6 4 4.4l-1.4.2c-.4-1.6-1.4-2.6-3-3.2z"/></svg>`,
  log: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M5 3.5h12.5v17H6.5A1.5 1.5 0 0 1 5 19z"/><path d="M5 17.5h12.5M8.5 3.5v14"/></svg>`,
  settings: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3.2"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/></svg>`,
};
const TAB_OF = { today: "today", session: "session", route: "board", force: "force", log: "log" };

const P = (cx, cy, r, deg) => [cx + r * Math.cos((deg * Math.PI) / 180), cy + r * Math.sin((deg * Math.PI) / 180)];
const arc = (cx, cy, r, a0, a1) => {
  const [x0, y0] = P(cx, cy, r, a0), [x1, y1] = P(cx, cy, r, a1);
  return `M${x0.toFixed(1)} ${y0.toFixed(1)} A${r} ${r} 0 ${a1 - a0 > 180 ? 1 : 0} 1 ${x1.toFixed(1)} ${y1.toFixed(1)}`;
};

function chip() {
  return `<div class="chip glass"><div class="crag">Pine Gully<small>Send conditions</small></div>
    <span class="v"><em>temp</em>14°</span><span class="v"><em>hum</em>52%</span>
    <span class="fr"><span>Friction</span>78</span></div>`;
}

function sendometer(v = 82, size = 260) {
  if (T === "headlamp") return moonGauge(v, size);
  const cx = 150, cy = 150, r = 118;
  const a = 180 + v * 1.8;
  const zones = [[0, 40, PAL.rest], [40, 75, PAL.train], [75, 100, PAL.send]];
  let g = "";
  if (T === "topo") {
    for (const k of [0, 1, 2]) g += `<path d="${arc(cx, cy, r - 16 - k * 11, 180, 360)}" fill="none" stroke="${PAL.soft}" stroke-width="1" stroke-dasharray="${k ? "3 5" : "none"}"/>`;
    for (const [z0, z1, c] of zones) g += `<path d="${arc(cx, cy, r, 180 + z0 * 1.8 + 1, 180 + z1 * 1.8 - 1)}" fill="none" stroke="${c}" stroke-width="7" stroke-linecap="butt"/>`;
    for (let i = 0; i <= 20; i++) { const [x0, y0] = P(cx, cy, r + 7, 180 + i * 9), [x1, y1] = P(cx, cy, r + (i % 5 ? 11 : 15), 180 + i * 9); g += `<line x1="${x0}" y1="${y0}" x2="${x1}" y2="${y1}" stroke="${PAL.line}" stroke-width="${i % 5 ? 1 : 1.6}"/>`; }
  } else if (T === "chalk") {
    for (const [z0, z1, c] of zones) g += `<path d="${arc(cx, cy, r, 180 + z0 * 1.8 + 1.5, 180 + z1 * 1.8 - 1.5)}" fill="none" stroke="${c}" stroke-width="16" stroke-dasharray="22 2 9 1.5" filter="url(#rough)"/>`;
    for (let i = 0; i <= 10; i++) { const [x0, y0] = P(cx, cy, r - 14, 180 + i * 18), [x1, y1] = P(cx, cy, r - 24, 180 + i * 18); g += `<line x1="${x0}" y1="${y0}" x2="${x1}" y2="${y1}" stroke="${PAL.line}" stroke-width="2.5" stroke-linecap="round" filter="url(#rough)"/>`; }
  } else {
    g += `<path d="${arc(cx, cy, r, 180 + 75 * 1.8, 360)} L${cx} ${cy}Z" fill="rgba(45,90,61,.14)"/>`;
    g += `<path d="${arc(cx, cy, r, 180, 360)}" fill="none" stroke="${PAL.line}" stroke-width="2.4"/>`;
    for (let i = 0; i <= 20; i++) { const [x0, y0] = P(cx, cy, r, 180 + i * 9), [x1, y1] = P(cx, cy, r - (i % 5 ? 8 : 14), 180 + i * 9); g += `<line x1="${x0}" y1="${y0}" x2="${x1}" y2="${y1}" stroke="${PAL.line}" stroke-width="${i % 5 ? 1.2 : 2.2}"/>`; }
  }
  const lbl = [["REST", 20], ["TRAIN", 57.5], ["SEND", 87.5]].map(([t, at]) => {
    const [x, y] = P(cx, cy, r - (T === "chalk" ? 40 : 34), 180 + at * 1.8);
    const on = (t === "SEND" && v >= 75) || (t === "TRAIN" && v >= 40 && v < 75) || (t === "REST" && v < 40);
    return `<text x="${x}" y="${y + 4}" text-anchor="middle" font-family="Barlow Condensed" font-weight="800" font-size="13" letter-spacing="1" fill="${on ? PAL.send : PAL.line}" opacity="${on ? 1 : 0.75}">${t}</text>`;
  }).join("");
  const [nx, ny] = P(cx, cy, r - 8, a);
  const needle = `<line x1="${cx}" y1="${cy}" x2="${nx}" y2="${ny}" stroke="${T === "chalk" ? PAL.line : PAL.accent}" stroke-width="${T === "chalk" ? 5 : 3.5}" stroke-linecap="round" ${T === "chalk" ? 'filter="url(#rough)"' : ""}/><circle cx="${cx}" cy="${cy}" r="9" fill="${T === "chalk" ? PAL.line : PAL.accent}"/>`;
  return `<svg class="gauge" viewBox="0 0 300 200" width="${size}" height="${size * 0.667}">
    <defs><filter id="rough"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="5"/><feDisplacementMap in="SourceGraphic" scale="3"/></filter></defs>
    ${g}${lbl}${needle}
    <text x="${cx}" y="${cy + 46}" text-anchor="middle" class="num" font-family="Barlow Condensed" font-weight="800" font-size="46" fill="${PAL.ink}">${v}</text>
  </svg>`;
}

function moonGauge(v, size) {
  const r = 70, cx = 100, cy = 92;
  const lit = v / 100;
  const k = Math.cos(Math.PI * lit) * r;
  const d = `M${cx} ${cy - r} A${r} ${r} 0 0 1 ${cx} ${cy + r} A${Math.abs(k)} ${r} 0 0 ${lit > 0.5 ? 1 : 0} ${cx} ${cy - r}Z`;
  const phase = (f, x) => { const kk = Math.cos(Math.PI * f) * 9; return `<g transform="translate(${x} 196)"><circle r="9" fill="#2A3144"/><path d="M0 -9 A9 9 0 0 1 0 9 A${Math.abs(kk)} 9 0 0 ${f > 0.5 ? 1 : 0} 0 -9Z" fill="${PAL.line}"/></g>`; };
  return `<svg class="gauge" viewBox="0 0 200 230" width="${size * 0.7}" height="${size * 0.8}">
    <defs><radialGradient id="mg"><stop offset=".55" stop-color="rgba(255,200,120,.38)"/><stop offset="1" stop-color="rgba(255,200,120,0)"/></radialGradient></defs>
    <circle cx="${cx}" cy="${cy}" r="${r + 26}" fill="url(#mg)"/>
    <circle cx="${cx}" cy="${cy}" r="${r}" fill="#1D2232"/>
    <path d="${d}" fill="#F1E6CF"/>
    <circle cx="${cx + 30}" cy="${cy - 34}" r="8" fill="#DCCFB3"/><circle cx="${cx + 46}" cy="${cy + 30}" r="6" fill="#DCCFB3"/><circle cx="${cx - 14}" cy="${cy + 44}" r="5" fill="#DCCFB3"/>
    <text x="${cx + 6}" y="${cy + 16}" text-anchor="middle" font-family="Barlow Condensed" font-weight="800" font-size="46" fill="#2A2216">${v}</text>
    ${phase(0.25, 40)}${phase(0.6, 100)}${phase(1, 160)}
    ${[["REST", 40], ["TRAIN", 100], ["SEND", 160]].map(([t, x]) => `<text x="${x}" y="225" text-anchor="middle" font-family="Barlow Condensed" font-weight="800" font-size="12" letter-spacing="1" fill="${t === "SEND" ? PAL.accent : PAL.line}" opacity="${t === "SEND" ? 1 : 0.7}">${t}</text>`).join("")}
  </svg>`;
}

function dial(label, val, sub, f) {
  const cx = 28, cy = 28, r = 22;
  const a = 135 + f * 270;
  const [nx, ny] = P(cx, cy, r - 4, a);
  const track = T === "chalk" ? 'stroke-dasharray="9 2" filter="url(#rough)"' : "";
  return `<div class="dial"><svg viewBox="0 0 56 56" width="52" height="52">
    <path d="${arc(cx, cy, r, 135, 405)}" fill="none" stroke="${PAL.soft}" stroke-width="${T === "chalk" ? 6 : 4}" ${track}/>
    <path d="${arc(cx, cy, r, 135, a)}" fill="none" stroke="${PAL.send}" stroke-width="${T === "chalk" ? 6 : 4}" ${track}/>
    <line x1="${cx}" y1="${cy}" x2="${nx}" y2="${ny}" stroke="${PAL.line}" stroke-width="2.4" stroke-linecap="round"/><circle cx="${cx}" cy="${cy}" r="3.5" fill="${PAL.line}"/>
  </svg><div><small>${label}</small><b>${val}</b><span class="mute" style="font-size:12px">${sub}</span></div></div>`;
}

function meterCard() {
  const note = T === "journal" ? `<div class="note" style="grid-column:1/-1">best in 3 weeks</div>` : "";
  return `<div class="glass card sheet">
    <div class="row"><span class="h">Send-o-meter</span><span class="sp"></span><span class="mute" style="font-size:13px">Sun 22 Nov</span></div>
    <div class="meter">${sendometer(82, WIDE ? 290 : 196)}
      ${dial("HRV", "64 ms", " +6", 0.72)}${dial("Sleep", "7h 40", " 92%", 0.86)}${note}</div>
  </div>`;
}

function tallySvg(n) {
  const groups = [];
  for (let i = 0; i < n; i += 5) {
    const c = Math.min(5, n - i);
    let d = "";
    for (let j = 0; j < Math.min(c, 4); j++) d += `M${4 + j * 7} 3 l${j % 2 ? 1 : -1} 20`;
    if (c === 5) d += "M0 18 L 30 6";
    groups.push(`<svg viewBox="-2 0 36 26" width="${34}" height="26"><path d="${d}" stroke="${PAL.line}" stroke-width="2.6" stroke-linecap="round" fill="none" ${T === "chalk" ? 'filter="url(#rough)"' : ""}/></svg>`);
  }
  return `<span class="tally">${groups.join("")}</span>`;
}

function weekViz() {
  const days = ["M", "T", "W", "T", "F", "S", "S"];
  const on = [1, 1, 0, 1, 0, 1, 0];
  if (T === "topo") {
    const xs = days.map((_, i) => 14 + i * 44), ys = [60, 50, 46, 34, 30, 16, 14];
    const route = xs.map((x, i) => `${i ? "L" : "M"}${x} ${ys[i]}`).join(" ");
    return `<svg viewBox="0 0 300 84" width="100%" height="84">
      <path d="M0 74 Q 60 64 110 50 T 220 22 T 300 6" fill="none" stroke="${PAL.soft}" stroke-width="1"/><path d="M0 80 Q 70 72 120 60 T 230 34 T 300 18" fill="none" stroke="${PAL.soft}" stroke-width="1" stroke-dasharray="3 4"/>
      <path d="${route}" fill="none" stroke="${PAL.accent}" stroke-width="2.5" stroke-dasharray="6 4"/>
      ${xs.map((x, i) => on[i] ? `<path d="M${x - 6} ${ys[i]} h12" stroke="${PAL.line}" stroke-width="3"/>` : `<circle cx="${x}" cy="${ys[i]}" r="2" fill="${PAL.soft}"/>`).join("")}
      ${xs.map((x, i) => `<text x="${x}" y="82" text-anchor="middle" font-family="Barlow" font-size="11" fill="${PAL.line}" opacity=".7">${days[i]}</text>`).join("")}
    </svg>`;
  }
  if (T === "chalk") return `<div class="row" style="gap:14px"><span class="num" style="font-size:44px">12</span><div><div class="mute" style="font-size:13px">sends this week</div>${tallySvg(12)}</div></div>`;
  if (T === "journal") {
    const hs = [34, 22, 0, 40, 0, 52, 0];
    return `<svg viewBox="0 0 300 80" width="100%" height="80">${hs.map((h, i) => `<rect x="${16 + i * 41}" y="${62 - h}" width="22" height="${h}" fill="none" stroke="${PAL.line}" stroke-width="1.8"/>${h ? `<path d="M${16 + i * 41} ${62 - h + 6} l22 -6" stroke="${PAL.line}" stroke-width="1"/>` : ""}<text x="${27 + i * 41}" y="77" text-anchor="middle" font-family="Barlow" font-size="11" fill="${PAL.line}">${days[i]}</text>`).join("")}<path d="M4 62 H296" stroke="${PAL.line}" stroke-width="1.4"/></svg>`;
  }
  return `<div class="row" style="justify-content:space-between;padding:6px 4px">${days.map((d, i) => `<div style="text-align:center"><div style="width:22px;height:22px;border-radius:50%;margin:0 auto 6px;${on[i] ? "background:#FFB547;box-shadow:0 0 16px rgba(255,181,71,.7)" : "border:1.5px solid rgba(245,237,223,.3)"}"></div><span class="mute" style="font-size:12px">${d}</span></div>`).join("")}</div>`;
}

function weekCard() {
  return `<div class="glass card sheet"><div class="row" style="margin-bottom:8px"><span class="h">This week</span><span class="sp"></span><span class="mute" style="font-size:13px">4 sessions · 12 sends</span></div>${weekViz()}</div>`;
}

function ticksCard() {
  const rows = [["V5", "Moon Arete", "Pine Gully · today", "Flash", 1], ["V4", "Slab Crack", "Pine Gully · today", "Send", 0], ["6B+", "Board 40°", "Home board · Fri", "Send", 0]];
  return `<div class="glass card sheet"><div class="h" style="margin-bottom:4px">Last ticks</div><div class="list">${rows.map(([g, n, s, t, f]) => `<div><span class="grade">${g}</span><span class="n">${n}<small>${s}</small></span><span class="sp"></span><span class="tag ${f ? "flash" : ""}">${T === "journal" ? t.toLowerCase() : t}</span></div>`).join("")}</div></div>`;
}

function startBtn() {
  return `<button class="btn">${ICON.session.replace("<svg", '<svg width="22" height="22"')}Send it</button>`;
}

function nav(active) {
  if (!WIDE) return `<nav class="tabbar glass">${["today", "session", "board", "force", "log"].map((k) => `<a class="${k === active ? "on" : ""}">${ICON[k]}${k[0].toUpperCase() + k.slice(1)}</a>`).join("")}</nav>`;
  return `<nav class="side glass"><div class="brand">${appIcon(T, 34)}Sendmeter</div>${["today", "session", "board", "force", "log", "settings"].map((k) => `<a class="${k === active ? "on" : ""}">${ICON[k]}${k[0].toUpperCase() + k.slice(1)}</a>`).join("")}</nav>`;
}

function today() {
  if (!WIDE) return `<div class="content">${chip()}<div style="height:${H * 0.47 - 120}px"></div>${meterCard()}${startBtn()}${weekCard()}</div>`;
  return `<div class="main">
    <div style="position:absolute;left:0;top:0;width:470px">${chip()}</div>
    <div style="position:absolute;left:0;bottom:0;width:470px">${meterCard()}</div>
    <div style="position:absolute;right:0;top:0;bottom:0;width:380px;display:flex;flex-direction:column;gap:12px">${startBtn()}${weekCard()}${ticksCard()}</div>
  </div>`;
}

function topoChart(wd, ht) {
  const sessions = [[0, "V3"], [1, "V3"], [2, "V4"], [3, "V4"], [4, "V4"], [5, "V5"], [6, "V5"], [7, "V5"]];
  const lvl = { V3: 0, V4: 1, V5: 2, V6: 3 };
  const bx = wd * 0.08, bw = wd * 0.84, top = ht * 0.08, base = ht * 0.92;
  const yOf = (g) => base - 30 - lvl[g] * ((base - top - 60) / 3);
  const outline = `M${bx} ${base} L${bx + bw * 0.06} ${base - ht * 0.42} L${bx + bw * 0.24} ${top + ht * 0.14} L${bx + bw * 0.5} ${top} L${bx + bw * 0.72} ${top + ht * 0.1} L${bx + bw * 0.9} ${base - ht * 0.48} L${bx + bw} ${base}Z`;
  const xs = sessions.map((_, i) => bx + bw * (0.16 + i * 0.095));
  const pts = sessions.map(([, g], i) => [xs[i] + (i % 2 ? 8 : -8), yOf(g) - i * 4]);
  const route = pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(0)} ${y.toFixed(0)}`).join(" ");
  let contours = "";
  for (let k = 1; k <= 4; k++) contours += `<path d="M${bx + k * 10} ${base} Q ${bx + bw * 0.3} ${top + ht * 0.1 + k * 26} ${bx + bw * 0.5} ${top + k * 22} T ${bx + bw - k * 10} ${base}" fill="none" stroke="${PAL.soft}" stroke-width="1" stroke-dasharray="${k % 2 ? "none" : "4 4"}"/>`;
  return `<svg viewBox="0 0 ${wd} ${ht}" width="100%" height="${ht}">
    <path d="${outline}" fill="rgba(221,230,238,.04)" stroke="${PAL.line}" stroke-width="2" stroke-linejoin="round"/>${contours}
    ${["V3", "V4", "V5", "V6"].map((g) => `<path d="M${bx - 4} ${yOf(g)} h${bw + 8}" stroke="${PAL.soft}" stroke-width=".8" stroke-dasharray="2 6"/><text x="${bx + bw + 6}" y="${yOf(g) + 4}" font-family="Barlow Condensed" font-weight="800" font-size="13" fill="${PAL.line}" opacity=".8">${g}</text>`).join("")}
    <path d="${route}" fill="none" stroke="${PAL.accent}" stroke-width="3" stroke-dasharray="7 5" stroke-linecap="round"/>
    ${pts.map(([x, y], i) => `<path d="M${x - 7} ${y} h14" stroke="${PAL.line}" stroke-width="3" stroke-linecap="round"/><text x="${x}" y="${y + 18}" text-anchor="middle" font-family="Barlow" font-size="10" fill="${PAL.line}" opacity=".65">${["Oct 4", "", "Oct 18", "", "Nov 1", "", "Nov 15", "Nov 22"][i]}</text>`).join("")}
    <circle cx="${pts[7][0]}" cy="${pts[7][1]}" r="7" fill="${PAL.accent}"/>
    <g transform="translate(${pts[7][0] + 10} ${pts[7][1] - 58}) scale(.22)">${roo("up", "topo")}</g>
  </svg>`;
}

function sessionRows(n) {
  const rows = [["Today", "Pine Gully", "7 sends · top V5"], ["Fri 20", "Home board", "5 sends · top 6B+"], ["Wed 18", "Force · max hangs", "PR 52.4 kg"], ["Mon 16", "Pine Gully", "6 sends · top V5"], ["Sat 14", "Moon Wall", "4 sends · top V4"]].slice(0, n);
  return `<div class="list">${rows.map(([d, w, s]) => `<div><span class="n" style="min-width:62px">${d}</span><span class="n">${w}<small>${s}</small></span></div>`).join("")}</div>`;
}

function logScreen() {
  const chart = `<div class="glass card sheet"><div class="row"><span class="h">Top grade · 8 weeks</span><span class="sp"></span><span class="tag flash">V3 → V5</span></div>${topoChart(WIDE ? 640 : 330, WIDE ? 560 : 300)}</div>`;
  const list = `<div class="glass card sheet"><div class="h" style="margin-bottom:4px">Sessions</div>${sessionRows(WIDE ? 5 : 3)}</div>`;
  const stats = `<div class="glass card sheet row" style="justify-content:space-between">${[["Sends", "41"], ["Flashes", "9"], ["Sessions", "14"]].map(([k, v]) => `<div><div class="h">${k}</div><div class="num" style="font-size:30px">${v}</div></div>`).join("")}</div>`;
  const pyr = [["V6", 0], ["V5", 5], ["V4", 14], ["V3", 22]];
  const pyramid = `<div class="glass card sheet"><div class="h" style="margin-bottom:8px">Sends by grade</div>${pyr.map(([g, n]) => `<div class="row" style="margin:6px 0"><span class="grade" style="font-size:16px">${g}</span><div style="flex:1;height:10px;border-top:1px dashed var(--glass-line)"><div style="width:${n * 4}%;height:8px;margin-top:-5px;background:${g === "V5" ? "var(--accent)" : "var(--mute)"};border-radius:4px"></div></div><span class="mute" style="width:24px;text-align:right">${n}</span></div>`).join("")}</div>`;
  if (!WIDE) return `<div class="content"><div class="title" style="margin:8px 4px 4px">Log</div>${chart}${stats}${list}</div>`;
  return `<div class="main"><div class="title" style="margin:6px 0 16px">Log</div><div style="display:grid;grid-template-columns:1fr 400px;gap:14px">${chart}<div style="display:flex;flex-direction:column;gap:14px">${stats}${list}${pyramid}</div></div></div>`;
}

function sessionScreen() {
  const current = `<div class="glass card sheet"><div class="row"><span class="h">On the problem</span><span class="sp"></span><span class="mute">try 3</span></div>
    <div class="row" style="margin:10px 0 14px"><span class="num" style="font-size:46px">V5</span><span class="n" style="font:600 20px var(--f-body)">Moon Arete<small class="mute" style="display:block;font:400 14px var(--f-body)">Pine Gully · granite</small></span></div>
    <div class="row" style="gap:10px"><button class="btn" style="flex:1">Log send</button><button class="btn ghost" style="flex:1">Fell</button></div></div>`;
  const moment = `<div class="glass card sheet moment">${rooSvg("up", "chalk", WIDE ? 96 : 70)}<div><div class="big">Flashed!</div><div class="mute">Slab Crack · V4 · first go</div></div></div>`;
  const grades = [["V5", 2], ["V4", 6], ["V3", 7]];
  const tallies = `<div class="glass card sheet"><div class="row" style="margin-bottom:6px"><span class="h">Sends today</span><span class="sp"></span><span class="num" style="font-size:28px">15</span></div><div class="list">${grades.map(([g, n]) => `<div><span class="grade">${g}</span>${tallySvg(n)}</div>`).join("")}</div></div>`;
  const head = `<div class="sheet-head" style="margin:8px 4px 4px"><span class="title">Session</span><span class="sp"></span><span class="num" style="font-size:30px;color:#fff">48:12</span></div>`;
  const probs = [["V5", "Moon Arete", "3 tries", ""], ["V4", "Slab Crack", "1 try", "Flash"], ["V5", "Pine Roof", "5 tries", "Send"], ["V3", "Warm-up Wall", "4 problems", "Send"], ["V4", "Mantle Lip", "2 tries", "Send"]];
  const list = `<div class="glass card sheet"><div class="h" style="margin-bottom:4px">Problems</div><div class="list">${probs.map(([g, n, t, r]) => `<div><span class="grade">${g}</span><span class="n">${n}<small>${t}</small></span><span class="sp"></span>${r ? `<span class="tag ${r === "Flash" ? "flash" : ""}">${r}</span>` : `<span class="mute">working</span>`}</div>`).join("")}</div></div>`;
  if (!WIDE) return `<div class="content">${head}${moment}${current}${tallies}</div>`;
  return `<div class="main">${head}<div style="display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:12px"><div style="display:flex;flex-direction:column;gap:14px">${moment}${current}</div><div style="display:flex;flex-direction:column;gap:14px">${tallies}${list}</div></div></div>`;
}

function forceCurve(wd, ht) {
  const n = 70, pts = [];
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    const f = t < 0.08 ? (t / 0.08) * 46 : t < 0.86 ? 46 + 6.4 * Math.sin(Math.min(1, (t - 0.08) / 0.2) * Math.PI / 2) - Math.max(0, t - 0.28) * 9 + Math.sin(i * 0.45) * 0.35 : Math.max(0, 50 - (t - 0.86) / 0.14 * 50);
    pts.push([t, f]);
  }
  const L = 34, R = wd - 14, Tp = 30, B = ht - 26;
  const X = (t) => L + t * (R - L), Y = (f) => B - (f / 60) * (B - Tp);
  const d = pts.map(([t, f], i) => `${i ? "L" : "M"}${X(t).toFixed(1)} ${Y(f).toFixed(1)}`).join(" ");
  const peak = pts.reduce((a, b) => (b[1] > a[1] ? b : a));
  return `<svg viewBox="0 0 ${wd} ${ht}" width="100%" height="${ht}">
    ${[0, 20, 40, 60].map((k) => `<text x="${L - 6}" y="${Y(k) + 4}" text-anchor="end" font-family="Barlow" font-size="11" fill="${PAL.line}" opacity=".7">${k}</text>`).join("")}
    ${[0, 2, 4, 6, 8, 10].map((s) => `<text x="${X(s / 10)}" y="${ht - 8}" text-anchor="middle" font-family="Barlow" font-size="11" fill="${PAL.line}" opacity=".7">${s}s</text>`).join("")}
    <path d="M${L} ${Y(50.6)} H${R}" stroke="#B04034" stroke-width="1.2" stroke-dasharray="5 4"/>
    <path d="${d} L${X(1)} ${B} L${L} ${B}Z" fill="rgba(45,90,61,.1)"/>
    <path d="${d}" fill="none" stroke="${PAL.line}" stroke-width="2.6" stroke-linejoin="round"/>
    <circle cx="${X(peak[0])}" cy="${Y(peak[1])}" r="6" fill="none" stroke="${PAL.accent}" stroke-width="2.4"/>
    <path d="M${X(peak[0]) + 10} ${Y(peak[1]) - 4} q 20 -6 34 -4" fill="none" stroke="${PAL.accent}" stroke-width="1.8"/>
    <text x="${X(peak[0]) + 48}" y="${Y(peak[1]) + 1}" font-family="Shantell Sans" font-weight="600" font-size="${WIDE ? 17 : 14}" fill="${PAL.accent}">new PR! 52.4 kg</text>
    <text x="${R}" y="${Y(50.6) - 7}" text-anchor="end" font-family="Shantell Sans" font-size="13" fill="#9A3A2E">old best 50.6</text>
  </svg>`;
}

function forceScreen() {
  const chart = `<div class="glass card sheet" style="padding-left:40px"><div class="row"><span class="h">Max hang · 20 mm · left</span><span class="sp"></span><span class="mute">kg</span></div>${forceCurve(WIDE ? 600 : 300, WIDE ? 470 : 220)}</div>`;
  const stats = `<div class="glass card sheet row" style="justify-content:space-between;padding-left:44px">${[["Peak", "52.4"], ["Avg", "46.1"], ["RFD", "310"]].map(([k, v]) => `<div><div class="h">${k}</div><div class="num" style="font-size:32px">${v}</div></div>`).join("")}</div>`;
  const pr = `<div class="glass card sheet moment" style="padding-left:44px">${rooSvg("hang", "journal", WIDE ? 84 : 60, `<path d="M40 14 H160" stroke="#1D2B47" stroke-width="7" stroke-linecap="round"/>`)}<div><div class="big">PR!</div><div class="mute">+1.8 kg on your best · 3 weeks</div></div></div>`;
  const hist = `<div class="glass card sheet" style="padding-left:44px"><div class="h" style="margin-bottom:4px">Recent</div><div class="list">${[["Today", "52.4 kg", "L"], ["Wed 18", "50.6 kg", "L"], ["Wed 18", "49.8 kg", "R"], ["Sun 15", "48.9 kg", "L"]].map(([d, v, s]) => `<div><span class="n" style="min-width:70px">${d}</span><span class="n">${v}</span><span class="sp"></span><span class="tag">${s === "L" ? "left" : "right"}</span></div>`).join("")}</div></div>`;
  const head = `<div class="title" style="margin:8px 4px 4px">Force</div>`;
  const wk = [44.2, 45.0, 46.3, 46.1, 47.8, 48.9, 50.6, 52.4];
  const tx = (i) => 30 + i * 46, ty = (v) => 100 - (v - 42) * 8;
  const trend = `<div class="glass card sheet" style="padding-left:44px"><div class="row"><span class="h">Peak · 8 weeks</span><span class="sp"></span><span class="note">+8.2 kg</span></div><svg viewBox="0 0 370 116" width="100%" height="116"><path d="${wk.map((v, i) => `${i ? "L" : "M"}${tx(i)} ${ty(v)}`).join(" ")}" fill="none" stroke="#1D2B47" stroke-width="2.4"/>${wk.map((v, i) => `<circle cx="${tx(i)}" cy="${ty(v)}" r="${i > 5 ? 5 : 3.5}" fill="${i > 5 ? "#2D5A3D" : "#F7F1E3"}" stroke="#1D2B47" stroke-width="1.8"/>`).join("")}<text x="${tx(7) - 8}" y="${ty(52.4) + 4}" text-anchor="end" font-family="Shantell Sans" font-size="13" fill="#2D5A3D">PR</text></svg></div>`;
  if (!WIDE) return `<div class="content">${head}${chart}${pr}${stats}</div>`;
  return `<div class="main">${head}<div style="display:grid;grid-template-columns:1fr 400px;gap:14px;margin-top:12px"><div style="display:flex;flex-direction:column;gap:14px">${chart}${stats}</div><div style="display:flex;flex-direction:column;gap:14px">${pr}${trend}${hist}</div></div></div>`;
}

function board(size) {
  const holds = { "1,9": "#43D17A", "3,10": "#43D17A", "2,7": "#4DA8FF", "4,6": "#4DA8FF", "3,4": "#4DA8FF", "5,3": "#4DA8FF", "6,1": "#FF5FB4", "7,8": "#FF9A3D", "5,10": "#FF9A3D" };
  const cols = 9, rows = 12, cell = size / cols;
  let g = "";
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    const c = holds[`${x},${y}`];
    const cx = cell * (x + 0.5), cy = cell * (y + 0.5);
    g += c ? `<circle cx="${cx}" cy="${cy}" r="${cell * 0.36}" fill="${c}" opacity="${T === "headlamp" ? 0.7 : 0.3}" filter="url(#hg)"/><circle cx="${cx}" cy="${cy}" r="${cell * 0.24}" fill="none" stroke="${c}" stroke-width="3"/><circle cx="${cx}" cy="${cy}" r="${cell * 0.1}" fill="#3A3F4D"/>`
      : `<circle cx="${cx}" cy="${cy}" r="${cell * 0.1}" fill="#3A3F4D"/>`;
  }
  return `<svg viewBox="0 0 ${size} ${cell * rows}" width="100%" style="display:block;border-radius:10px;background:radial-gradient(ellipse 70% 60% at 50% 40%, #2A2E3A, #12151D)"><defs><filter id="hg" x="-2" y="-2" width="5" height="5"><feGaussianBlur stdDeviation="7"/></filter></defs>${g}</svg>`;
}

function routeScreen() {
  const b = `<div class="glass card sheet"><div class="row" style="margin-bottom:10px"><span class="h">Home board · 40°</span><span class="sp"></span><span class="mute" style="font-size:13px">lit</span></div>${board(WIDE ? 380 : 330)}</div>`;
  const info = `<div class="glass card sheet"><div class="row"><span class="num" style="font-size:46px">6B+</span><span class="n" style="font:600 20px var(--f-body)">Moonrise<small class="mute" style="display:block;font:400 14px var(--f-body)">★★★ · 212 ascents</small></span></div>
    <div class="row" style="margin-top:12px;justify-content:space-between">${[["Your tries", "4"], ["Sent", "Fri"], ["Best", "4 moves"]].map(([k, v]) => `<div><div class="h">${k}</div><div style="font:700 20px var(--f-body)">${v}</div></div>`).join("")}</div></div>`;
  const btns = `<div class="row" style="gap:10px"><button class="btn ghost" style="flex:1">Light it</button><button class="btn" style="flex:1">Log send</button></div>`;
  const legend = `<div class="glass card sheet row" style="justify-content:space-between;font-size:13px">${[["#43D17A", "Start"], ["#4DA8FF", "Hand"], ["#FF5FB4", "Finish"], ["#FF9A3D", "Foot"]].map(([c, t]) => `<span class="row" style="gap:6px"><i style="width:12px;height:12px;border-radius:50%;border:3px solid ${c};box-shadow:0 0 10px ${c}"></i>${t}</span>`).join("")}</div>`;
  const head = `<div class="title" style="margin:8px 4px 4px">Board</div>`;
  if (!WIDE) return `<div class="content">${head}${b}${btns}</div>`;
  return `<div class="main">${head}<div style="display:grid;grid-template-columns:440px 400px;gap:14px;margin-top:12px;justify-content:center">${b}<div style="display:flex;flex-direction:column;gap:14px">${info}${legend}${btns}${ticksCard()}</div></div></div>`;
}

function appIcon(t, size) {
  const [bg, moon, fur, light, eye] = {
    topo: ["#18233A", "#EEEBDD", "#7A5238", "#E9D5B8", "#18233A"],
    chalk: ["#45474C", "#C8452F", "#7A5A42", "#F1ECE2", "#45474C"],
    journal: ["#2D5A3D", "#F4E9D4", "#B88A62", "#F4E9D4", "#1D2B47"],
    headlamp: ["#0D1324", "#FFB547", "#4A3424", "#F1DDC0", "#0D1324"],
  }[t];
  return `<svg viewBox="0 0 100 100" width="${size}" height="${size}" style="border-radius:${size * 0.225}px;display:block">
    <rect width="100" height="100" fill="${bg}"/>
    <circle cx="80" cy="25" r="13" fill="${moon}"/>
    <polygon points="12,100 20,80 38,70 62,70 80,80 88,100" fill="${fur}"/>
    <polygon points="38,100 42,80 58,80 62,100" fill="${light}"/>
    <polygon points="36,38 29,0 46,31" fill="${fur}"/><polygon points="54,31 71,0 64,38" fill="${fur}"/>
    <polygon points="37,33 32,10 43,30" fill="${light}"/><polygon points="57,30 68,10 63,33" fill="${light}"/>
    <polygon points="31,50 35,36 45,30 55,30 65,36 69,50 63,68 50,77 37,68" fill="${fur}"/>
    <polygon points="40,58 50,54 60,58 58,71 50,76 42,71" fill="${light}"/>
    <polygon points="45,58 55,58 50,63" fill="${eye}"/>
    <circle cx="40" cy="46" r="3.2" fill="${eye}"/><circle cx="60" cy="46" r="3.2" fill="${eye}"/>
  </svg>`;
}

function scenesSheet() {
  const states = ["dawn", "golden", "night", "rain", "fog"];
  const wd = WIDE ? 252 : 168, ht = Math.round(wd * 1.7);
  const cols = WIDE ? 5 : 2;
  return `<div class="sheetpage" style="${WIDE ? "" : "padding:28px 20px"}"><h1>Today's scene · clock and weather</h1>
    <div style="display:grid;grid-template-columns:repeat(${cols},${wd}px);gap:${WIDE ? 22 : 14}px">${states.map((s) => `<figure><div style="width:${wd}px;height:${ht}px;border-radius:18px;overflow:hidden">${scene(s, wd, ht, { rooScale: WIDE ? 0.3 : 0.2, ground: Math.round(ht * 0.62) })}</div><figcaption>${{ dawn: "Dawn", golden: "Golden hour", night: "Night, moon", rain: "Rain", fog: "Fog" }[s]}<small>${{ dawn: "roo chalks up", golden: "roo rests under the tree", night: "roo watches the moon", rain: "roo shelters under the overhang", fog: "roo sits it out" }[s]}</small></figcaption></figure>`).join("")}</div></div>`;
}

function iconsSheet() {
  const names = { topo: "Night Topo · default", chalk: "Chalk & Granite", journal: "Field Journal", headlamp: "Headlamp Session" };
  const big = WIDE ? 200 : 140, sm = WIDE ? 64 : 54;
  const wall = (bg) => `<div style="display:flex;gap:${WIDE ? 26 : 16}px;padding:${WIDE ? 26 : 16}px;border-radius:18px;background:${bg}">${Object.keys(names).map((t) => appIcon(t, sm)).join("")}</div>`;
  return `<div class="sheetpage" style="${WIDE ? "" : "padding:28px 20px"}"><h1>App icon · one per theme</h1>
    <div style="display:grid;grid-template-columns:repeat(${WIDE ? 4 : 2},${big}px);gap:${WIDE ? 36 : 22}px">${Object.entries(names).map(([t, n]) => `<figure>${appIcon(t, big)}<figcaption>${n}</figcaption></figure>`).join("")}</div>
    <div style="display:flex;flex-direction:${WIDE ? "row" : "column"};gap:16px;margin-top:${WIDE ? 40 : 26}px">${wall("linear-gradient(135deg,#E9E4F2,#C9D8EA)")}${wall("linear-gradient(135deg,#0B0E18,#26304A)")}</div></div>`;
}

function render() {
  if (S === "scenes") return (document.body.innerHTML = scenesSheet());
  if (S === "icons") return (document.body.innerHTML = iconsSheet());
  const screen = { today, log: logScreen, session: sessionScreen, force: forceScreen, route: routeScreen }[S]();
  const dim = S === "today" ? "" : "dim";
  document.body.innerHTML = `<div class="page ${WIDE ? "p1440" : "p390"} ${dim}">
    <div class="bg">${scene(SCENE_OF[T], W, H, { hand: T, rooScale: WIDE ? 0.5 : 0.36 })}</div><div class="beam"></div>
    ${WIDE ? "" : `<div class="status"><span>9:41</span><i></i></div>`}
    ${screen}${nav(TAB_OF[S])}</div>`;
}
document.fonts.ready.then(render);
render();
