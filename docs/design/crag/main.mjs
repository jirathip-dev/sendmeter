import { local, mount } from "./blocks/blocks.js";
import { KINDS, moonGauge, forceCurve } from "./kinds.mjs";
import { SCREENS } from "./screens.mjs";
import { scene, WEATHERS } from "./pack/scene.mjs";
import { roo, POSES, COLOURS, rigJson } from "./pack/roo.mjs";
import { ICONS, icon } from "./pack/icons.mjs";

const q = new URLSearchParams(location.search);
const S = q.get("s") || "today";
const M = q.get("m") || "clear";
const W = innerWidth, H = innerHeight, WIDE = W >= 900;
const TABS = ["today", "session", "board", "force", "log"];
const B = document.body;

const svgUrl = (s) => `url("data:image/svg+xml;utf8,${encodeURIComponent(s.replace(/<svg /, '<svg xmlns="http://www.w3.org/2000/svg" '))}")`;
const TAB_ICONS = {
  today: `<svg viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2.2" stroke-linejoin="round"><path d="M2 20 9 8l4 6 3-4 6 10z"/><circle cx="17.5" cy="4.5" r="2.2" fill="#000" stroke="none"/></svg>`,
  session: roo("sit", { size: 24, edge: false, box: [-70, -205, 150, 245] }),
  board: `<svg viewBox="0 0 24 24"><g fill="#000">${[5, 12, 19].flatMap((y) => [5, 12, 19].map((x) => `<circle cx="${x}" cy="${y}" r="2.4"/>`)).join("")}</g></svg>`,
  force: roo("hang", { size: 24, edge: false, box: [-90, -240, 180, 340] }),
  log: `<svg viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2.2" stroke-linejoin="round"><path d="M5 3.5h12.5v17H6.5A1.5 1.5 0 0 1 5 19z"/><path d="M5 17.5h12.5M9 3.5v14"/></svg>`,
};
const tabCss = () => `<style>${TABS.map((t, i) => `.b-tab:nth-child(${i + 1}){--ico:${svgUrl(TAB_ICONS[t])}}`).join("")}</style>`;

const status = () => (WIDE ? "" : `<div class="status"><span>9:41</span><i></i></div>`);
const bg = (dim) => `<div class="bgscene ${dim ? "dim" : ""}">${scene(W, H, M)}</div><span class="scenetag">stand-in · scene layer</span>`;

KINDS["crag-icons"] = () => {
  const d = document.createElement("div");
  d.className = "b-app glass standin";
  d.innerHTML = `<span class="tagbox">stand-in · icon grid</span><div style="display:grid;grid-template-columns:repeat(${WIDE ? 4 : 3},1fr);gap:18px 10px;padding-top:14px">${ICONS.map((ic, i) => `<div style="text-align:center"><div style="display:inline-block;padding:4px;border-radius:24px;${i === 0 ? "box-shadow:0 0 0 3px var(--l)" : ""}">${icon(ic.id, WIDE ? 96 : 84)}</div><div style="font:600 13px var(--body);margin-top:6px;color:${i === 0 ? "var(--l)" : "var(--fg)"}">${ic.label}${i === 0 ? " · default" : ""}</div></div>`).join("")}</div>`;
  return d;
};

function app() {
  const sc = SCREENS[S];
  const parent = sc.tab;
  B.classList.add(`s-${S}`);
  if (sc.pushed) B.classList.add("pushed");
  B.insertAdjacentHTML("afterbegin", bg(S !== "today") + status() + tabCss());
  const blocks = WIDE && sc.wideExtra ? [...sc.blocks, ...sc.wideExtra] : sc.blocks;
  const screen = { type: "screen", id: S, title: sc.title, ...(sc.back ? { back: sc.back } : {}), blocks };
  const blank = (p) => ({ type: "screen", id: p, title: p, blocks: [] });
  const src = local({ screen: (path) => (path === `/${parent}` ? screen : blank(path.slice(1))), act: () => ({ ops: [] }) });
  const at = (p) => ({ compact: p, wide: p });
  mount({
    root: B,
    blocks: KINDS,
    layout: { format: 1, root: { type: "nav", id: "root", place: at("inline"), transition: "push", slots: { main: TABS.map((t) => ({ type: "screen", id: t, source: "app", path: `/${t}`, label: t[0].toUpperCase() + t.slice(1), place: at("strip"), transition: "none" })) } } },
    sources: { app: src },
  });
  const go = () => { const b = document.querySelectorAll(".b-tab")[TABS.indexOf(parent)]; if (b && !b.classList.contains("on")) b.click(); };
  const fix = () => document.querySelectorAll(".b-screen__title").forEach((t) => { if (t.closest(`[data-id="${S}"]`)) t.textContent = sc.title; });
  go(); setTimeout(() => { go(); fix(); }, 50); setTimeout(fix, 300);
}

const sheetHead = (t, sub) => `<div style="display:flex;align-items:baseline;gap:14px;margin:0 0 18px"><h1 style="font:700 ${WIDE ? 30 : 24}px var(--display);margin:0">${t}</h1>${sub ? `<span style="color:var(--mute);font-size:14px">${sub}</span>` : ""}</div>`;
const sheet = (html) => { B.style.overflow = "visible"; B.innerHTML = `<div style="position:fixed;inset:0;background:radial-gradient(ellipse at 50% 30%,#141945,#05071A)"></div><div style="position:relative;padding:${WIDE ? "36px 40px" : "26px 18px"}">${html}</div>`; };

function loading() {
  B.innerHTML = `<div class="bgscene">${scene(W, H, "clear", { roo: false, seed: 19 })}</div>
  <div style="position:fixed;inset:0;background:linear-gradient(180deg,rgba(7,10,31,0) 40%,rgba(7,10,31,.75))"></div>
  <div style="position:fixed;left:50%;top:${WIDE ? 14 : 24}%;transform:translateX(-50%) rotate(-8deg)">${roo("dyno", { size: WIDE ? 300 : 230 })}</div>
  <svg style="position:fixed;left:0;top:0" width="${W}" height="${H}" aria-hidden="true"><path d="M${W / 2 - 70} ${H * 0.62} Q${W / 2 - 110} ${H * 0.4} ${W / 2 - 20} ${H * (WIDE ? 0.22 : 0.27)}" fill="none" stroke="#C9C6F0" stroke-width="2.5" stroke-dasharray="2 9" stroke-linecap="round" opacity=".7"/></svg>
  <div style="position:fixed;left:0;right:0;bottom:${WIDE ? 90 : 110}px;text-align:center">
    <div style="font:700 ${WIDE ? 64 : 46}px var(--display);color:#fff;letter-spacing:.01em">Sendmeter</div>
    <div style="width:${WIDE ? 220 : 170}px;height:5px;border-radius:3px;background:rgba(238,240,250,.15);margin:18px auto 0;overflow:hidden"><div style="width:62%;height:100%;background:#B9A8FF;border-radius:3px"></div></div>
  </div>`;
}

function icons() {
  const big = WIDE ? 200 : 104;
  sheet(sheetHead("App icons", "9 close crops of the roo kit · Profile is the default") +
    `<div style="display:flex;align-items:flex-end;gap:${WIDE ? 22 : 12}px;flex-wrap:wrap;margin-bottom:26px">${icon("profile", WIDE ? 300 : 200)}${[180, 120, 87, 60, 40, 29].map((s) => `<div style="text-align:center">${icon("profile", s)}<div style="font-size:11px;color:var(--mute);margin-top:4px">${s}</div></div>`).join("")}</div>
    <div style="display:grid;grid-template-columns:repeat(${WIDE ? 9 : 3},1fr);gap:16px">${ICONS.map((ic) => `<div style="text-align:center">${icon(ic.id, WIDE ? 132 : big)}<div style="font:600 13px var(--body);margin-top:6px">${ic.label}</div></div>`).join("")}</div>
    <div style="margin-top:22px;display:flex;flex-direction:column;gap:10px">${[40, 29].map((px) => `<div style="display:flex;align-items:center;gap:${WIDE ? 18 : 8}px;flex-wrap:wrap"><span style="width:44px;font-size:11px;color:var(--mute)">${px} px</span>${ICONS.map((ic) => icon(ic.id, px)).join("")}</div>`).join("")}</div>`);
}

function mascots() {
  const poses = ["stand", "sit", "chalk", "crimp", "hang", "dyno", "flash", "send", "fall", "rest", "pr", "shelter", "moon", "topout", "deadhang", "tongue"];
  const where = { stand: "kit base", sit: "Session tab", chalk: "dawn, first run", crimp: "icon", hang: "Force tab", dyno: "loading", flash: "Flashed!", send: "Sent", fall: "Whipper, errors", rest: "empty, fog", pr: "PR!", shelter: "rain, can't read", moon: "clear night", topout: "Send icon", deadhang: "Rest icon", tongue: "Tongue icon" };
  const sz = WIDE ? 120 : 100;
  sheet(sheetHead("The roo kit", "13 parts · every pose re-posed from them, never redrawn") +
    `<div style="display:grid;grid-template-columns:repeat(${WIDE ? 7 : 3},minmax(0,1fr));gap:4px 6px">${poses.map((p) => `<div style="text-align:center">${roo(p, { size: sz })}<div style="font:600 12px var(--body)">${POSES[p].label}</div><div style="font-size:10.5px;color:var(--mute)">${where[p]}</div></div>`).join("")}</div>`);
}

function model() {
  const sz = WIDE ? 230 : 170;
  const sw = Object.entries({ fur: COLOURS.fur, "far limb": COLOURS.far, "near arm": COLOURS.limb, "inner ear": COLOURS.ear, muzzle: COLOURS.muzzle, spots: COLOURS.spot, blush: COLOURS.blush, "shoe upper": COLOURS.upper, rubber: COLOURS.rubber, "velcro strap": COLOURS.strap, outline: COLOURS.line, "bag band": COLOURS.band, "chalk bag": COLOURS.bag, rim: COLOURS.rim });
  const grid = (svg) => `<div style="position:relative;display:inline-block">${svg}<div style="position:absolute;inset:0;background:repeating-linear-gradient(180deg,transparent 0 ${sz * 64 / 240 - 1}px,rgba(185,168,255,.25) ${sz * 64 / 240 - 1}px ${sz * 64 / 240}px)"></div></div>`;
  const parts = rigJson().side;
  sheet(sheetHead("Roo model sheet", "front, side, back · proportions · colours") +
    `<div style="display:flex;gap:${WIDE ? 30 : 6}px;flex-wrap:${WIDE ? "nowrap" : "wrap"};justify-content:center">
      ${[["front", "Front"], ["stand", "Side"], ["back", "Back"]].map(([p, l]) => `<div style="text-align:center">${grid(roo(p, { size: WIDE ? sz : 112 }))}<div style="font:700 14px var(--display);margin-top:4px">${l}</div></div>`).join("")}
      <div style="min-width:${WIDE ? 380 : 340}px;font-size:13px;line-height:1.55">
        <div style="font:700 13px var(--display);letter-spacing:.1em;color:var(--mute);margin-bottom:6px">PROPORTIONS</div>
        <div>Head = 1 unit (64, a circle). Standing height 3.2 heads with ears, 2.6 without.</div>
        <div>Body 1.1 heads, a round belly. Ears 0.65 head, round-tipped. Arms 0.75 head, stubby.</div>
        <div>Legs 0.9 head: a round haunch, a short shin, a big climbing shoe. Tail 0.9 head.</div>
        <div>Flat fills, no inner lines. One thin flat rim (${COLOURS.rim}) round the silhouette and the near arm.</div>
        <div style="font:700 13px var(--display);letter-spacing:.1em;color:var(--mute);margin:12px 0 6px">PARTS (${parts.length})</div>
        <div style="color:var(--mute)">${parts.map((p) => p.part).join(" · ")}</div>
        <div style="font:700 13px var(--display);letter-spacing:.1em;color:var(--mute);margin:12px 0 6px">COLOURS</div>
        <div style="display:grid;grid-template-columns:repeat(${WIDE ? 4 : 4},1fr);gap:8px">${sw.map(([n, c]) => `<div><div style="height:26px;border-radius:8px;background:${c};border:1px solid rgba(238,240,250,.2)"></div><div style="font-size:11px">${n}</div><div style="font-size:10.5px;color:var(--mute)">${c}</div></div>`).join("")}</div>
      </div></div>`);
}

function buttons() {
  const col = (t, cls, note) => `<div style="flex:1;min-width:${WIDE ? 300 : 0}px"><div style="font:700 13px var(--display);letter-spacing:.1em;color:var(--mute);margin-bottom:8px">${t}</div><button class="${cls}">Start session</button><div style="font-size:12.5px;color:var(--mute);margin-top:8px">${note}</div></div>`;
  sheet(sheetHead("Moonstone", "the primary button · rest and press") +
    `<div style="display:flex;flex-direction:${WIDE ? "row" : "column"};gap:${WIDE ? 36 : 22}px;max-width:1100px">
      ${col("REST", "primary", "Deep violet, faint granite grain, a thin pearl rim. No shimmer.")}
      ${col("PRESS", "primary pressed", "A soft shimmer glint sweeps across while held.")}
      ${col("OTHERS", "", "Every other button: violet text on a faint violet pill.")}
    </div>
    <div style="margin-top:${WIDE ? 34 : 24}px;display:flex;gap:16px;align-items:center"><div style="width:${WIDE ? 420 : 340}px;height:${WIDE ? 120 : 96}px;border-radius:999px;border:2px solid transparent;background:var(--grain) padding-box,linear-gradient(180deg,#5242AE,var(--moonstone) 55%,#3B2E86) padding-box,var(--pearl) border-box;box-shadow:0 8px 24px rgba(40,26,110,.45)"></div><div style="font-size:12.5px;color:var(--mute)">${WIDE ? "The surface at 4×: grain and rim." : "Surface at 4×"}</div></div>`);
}

function states() {
  const ws = Object.keys(WEATHERS);
  const w = WIDE ? 300 : 170, h = WIDE ? 650 : 368;
  sheet(sheetHead("Weather inside the night", "the same scene; only the weather layers and the roo change") +
    `<div style="display:grid;grid-template-columns:repeat(${WIDE ? 4 : 2},${w}px);gap:16px;justify-content:center">${ws.map((m) => `<div><div style="width:${w}px;height:${h}px;border-radius:22px;overflow:hidden;border:1px solid var(--edge)">${scene(w, h, m)}</div><div style="font:700 14px var(--display);margin-top:6px;text-align:center">${WEATHERS[m]}</div></div>`).join("")}</div>`);
}

function watch() {
  const face = (title, body) => `<div style="text-align:center"><div style="width:198px;height:242px;border-radius:52px;background:#000;border:7px solid #23263A;padding:16px 14px;box-sizing:border-box;display:flex;flex-direction:column;gap:6px;overflow:hidden">${body}</div><div style="font:600 13px var(--body);margin-top:8px">${title}</div></div>`;
  const pill = (t, p) => `<div style="height:40px;border-radius:20px;display:grid;place-items:center;font:700 16px var(--display);${p ? "border:1.5px solid transparent;background:var(--grain) padding-box,linear-gradient(180deg,#5242AE,var(--moonstone) 55%,#3B2E86) padding-box,var(--pearl) border-box;color:var(--on-moonstone)" : "background:rgba(185,168,255,.16);color:var(--l)"}">${t}</div>`;
  const small = (v, k) => `<div><div style="font:700 22px var(--display)">${v}</div><div style="font-size:11px;color:var(--mute)">${k}</div></div>`;
  sheet(sheetHead("Apple Watch", "every session and force screen fits with no scrolling") +
    `<div style="display:flex;gap:${WIDE ? 26 : 14}px;flex-wrap:wrap;justify-content:center">
    ${face("Start", `<div style="font:700 15px var(--display);color:var(--mute);text-align:left">Pine Gully · 78</div><div style="flex:1;display:grid;place-items:center">${moonGauge(82, 110)}</div>${pill("Start session", true)}`)}
    ${face("Session", `<div style="display:flex;justify-content:space-between;text-align:left">${small("1:12", "time")}${small("5/9", "sends")}${small("142", "bpm")}</div><div style="font:600 13px var(--body);text-align:left;color:var(--mute)">Moon Arete · V5</div><div style="flex:1"></div>${pill("Sent", true)}${pill("Fell")}`)}
    ${face("Force", `<div style="font:700 13px var(--display);text-align:left;color:var(--mute)">Max hang · R</div><div style="font:700 40px/1 var(--display);text-align:left">52.4<span style="font-size:15px;color:var(--mute)"> kg</span></div><div style="flex:1;display:flex;align-items:flex-end">${forceCurve(170, 90)}</div>`)}
    ${face("Flashed!", `<div style="flex:1;display:grid;place-items:center">${roo("flash", { size: 100 })}</div><div style="font:700 26px var(--display)">Flashed!</div><div style="font-size:12px;color:var(--mute)">Moon Arete · V5</div>`)}
    </div>`);
}

function one() { sheet(`<div style="display:flex;flex-wrap:wrap;gap:12px">${(q.get("id") || "profile").split(",").map((i) => icon(i, +(q.get("px") || 400))).join("")}</div>`); }

const SHEETS = { one, buttons, loading, icons, mascots, model, states, watch };
if (SHEETS[S]) SHEETS[S](); else app();
