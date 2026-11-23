const SKY = {
  night: { sky: ["#04061A", "#0A0F2E", "#151B45", "#232A5C"], ridge: ["#12163A", "#0C1028"], rock: ["#25283C", "#363A56", "#1A1C2E", "#111322"], ground: "#12141F", canopy: ["#0E1426", "#151D34"], light: "#ECEEF8", glow: "rgba(200,186,255,.38)", stars: 1, lightest: "#ECEEF8" },
  dawn: { sky: ["#05071C", "#18184A", "#4E3874", "#B4688E"], ridge: ["#2A2350", "#1D1A3C"], rock: ["#2A2742", "#403A60", "#1E1B30", "#151324"], ground: "#16141F", canopy: ["#141632", "#1E1E40"], light: "#F4ECF8", glow: "rgba(255,179,220,.4)", stars: 0.55, lightest: "#F0B8C8" },
  rain: { sky: ["#04061A", "#0C1128", "#161D36", "#212944"], ridge: ["#161B34", "#10142A"], rock: ["#222636", "#30354C", "#191C2A", "#11131F"], ground: "#11131D", canopy: ["#0F1526", "#141C30"], light: "#B9BFD8", glow: "rgba(170,190,230,.22)", stars: 0.2, lightest: "#9AA6C0" },
  fog: { sky: ["#05071C", "#0E1230", "#1A1F44", "#262C56"], ridge: ["#1C2146", "#151A3A"], rock: ["#262A3E", "#373B56", "#1C1E30", "#141624"], ground: "#141621", canopy: ["#131A30", "#1A223A"], light: "#D6D8EA", glow: "rgba(200,205,235,.3)", stars: 0.35, lightest: "#A9AEC4" },
};

const ARM = {
  sit: ["M80 152 Q 84 168 94 172", "M120 152 Q 116 168 106 172"],
  rest: ["M80 152 Q 84 168 94 172", "M120 152 Q 116 168 106 172"],
  look: ["M80 152 Q 84 168 94 172", "M120 152 Q 116 168 106 172"],
  chalk: ["M78 152 Q 60 176 50 194", "M120 152 Q 116 168 106 172"],
  shelter: ["M76 154 Q 96 190 124 178", "M124 154 Q 104 188 78 180"],
  flash: ["M78 150 Q 48 126 36 88", "M122 150 Q 152 126 164 88"],
  send: ["M80 152 Q 84 168 94 172", "M122 150 Q 154 128 158 90"],
  pr: ["M78 152 Q 44 152 46 120", "M122 152 Q 156 152 154 120"],
  crimp: ["M80 152 Q 84 168 94 172", "M122 148 Q 156 104 150 44"],
  hang: ["M78 150 Q 42 110 48 34", "M122 150 Q 158 110 152 34"],
  dyno: ["M78 150 Q 38 104 42 22", "M122 150 Q 162 104 158 22"],
  fall: ["M80 154 Q 48 144 30 156", "M120 154 Q 152 144 170 156"],
};
const STRETCH = new Set(["hang", "dyno", "fall", "flash", "crimp"]);
const EARS = '<ellipse class="f" cx="74" cy="46" rx="18" ry="28" transform="rotate(-16 74 46)"/>';
const PROPS = {
  chalk: `<path class="bag" d="M30 206 l4 -26 h28 l4 26Z"/><rect class="rim" x="31" y="176" width="34" height="7" rx="3"/>`,
  crimp: `<rect class="hold" x="132" y="30" width="36" height="14" rx="7"/>`,
  hang: `<rect class="bar" x="20" y="22" width="160" height="12" rx="6"/>`,
  flash: `<path class="zap" d="M176 30 l-16 30 h12 l-8 26 l22 -34 h-12 l8 -22Z"/>`,
  pr: `<path class="zap" d="M100 -6 l7 14 15 2 -11 10 3 15 -14 -7 -14 7 3 -15 -11 -10 15 -2Z"/>`,
  send: `<path class="ln2" d="M150 70 v-56 M150 16 h26 l-6 9 6 9 h-26"/>`,
  rest: `<text class="zz" x="140" y="44">z</text><text class="zz" x="158" y="24" style="font-size:22px">z</text>`,
  fall: `<path class="ln2" d="M24 118 h-16 M28 132 h-20 M176 118 h16 M172 132 h20"/>`,
};

function roo(pose = "sit", props = false) {
  const [a1, a2] = ARM[pose];
  const tilt = { look: -12, shelter: 6, fall: 16, rest: 8 }[pose] || 0;
  const eL = pose === "shelter" ? "rotate(-30 80 70)" : pose === "fall" ? "rotate(-18 86 62)" : pose === "rest" ? "rotate(-10 86 62)" : "";
  const eR = pose === "shelter" ? "rotate(30 120 70)" : pose === "fall" ? "rotate(22 114 62)" : pose === "rest" ? "rotate(10 114 62)" : "";
  const feet = STRETCH.has(pose)
    ? `<ellipse class="f" cx="84" cy="236" rx="10" ry="16" transform="rotate(12 84 236)"/><ellipse class="f" cx="116" cy="236" rx="10" ry="16" transform="rotate(-12 116 236)"/>`
    : `<ellipse class="f" cx="78" cy="236" rx="24" ry="10"/><ellipse class="f" cx="122" cy="236" rx="24" ry="10"/>`;
  const body = { shelter: "translate(0 12) scale(1 .95)", dyno: "rotate(-8 100 160)", fall: "rotate(22 100 160)" }[pose] || "";
  const happy = ["flash", "send", "pr", "dyno"].includes(pose);
  const eyes = pose === "rest" ? `<path class="lw" d="M77 98 q6 5 12 0 M111 98 q6 5 12 0"/>`
    : happy ? `<path class="lw" d="M77 100 q6 -7 12 0 M111 100 q6 -7 12 0"/>`
    : `<circle class="hi" cx="83" cy="98" r="6.5"/><circle class="hi" cx="117" cy="98" r="6.5"/><circle class="e" cx="84" cy="99" r="4"/><circle class="e" cx="118" cy="99" r="4"/><circle class="hi" cx="85.5" cy="97" r="1.5"/><circle class="hi" cx="119.5" cy="97" r="1.5"/>`;
  const brow = pose === "shelter" ? `<path class="lw" d="M76 86 l10 3 M124 86 l-10 3"/>` : "";
  const mouth = pose === "fall" ? `<ellipse class="e" cx="100" cy="128" rx="4" ry="5"/>` : happy ? `<path class="m" d="M92 123 Q100 134 108 123Z"/>` : `<path class="ln" d="M93 125 q3.5 4 7 0 q3.5 4 7 0"/>`;
  const shape = (art) => `<g transform="${body}">
    <path class="f" d="M122 198 C 174 198 202 220 198 246 C 176 248 146 240 116 228Z"/>
    ${feet}
    <ellipse class="f" cx="100" cy="186" rx="42" ry="48"/>
    ${art ? `<ellipse class="b" cx="100" cy="194" rx="26" ry="32"/>` : ""}
    <path class="ao" d="${a1}"/><path class="ao" d="${a2}"/>
    <g transform="rotate(${tilt} 100 110)">
      <g transform="${eL}">${EARS}${art ? `<ellipse class="i" cx="74" cy="46" rx="9" ry="17" transform="rotate(-16 74 46)"/>` : ""}</g>
      <g transform="${eR} translate(200 0) scale(-1 1)">${EARS}${art ? `<ellipse class="i" cx="74" cy="46" rx="9" ry="17" transform="rotate(-16 74 46)"/>` : ""}</g>
      <ellipse class="f" cx="100" cy="98" rx="46" ry="42"/>
      ${art ? `<ellipse class="f" cx="100" cy="124" rx="24" ry="18"/><ellipse class="l" cx="100" cy="124" rx="20" ry="14"/><ellipse class="e" cx="100" cy="113" rx="7" ry="4.6"/>${eyes}${brow}${mouth}
      <circle class="c" cx="68" cy="114" r="6.5"/><circle class="c" cx="132" cy="114" r="6.5"/>` : ""}
    </g>
    ${art ? `<path class="a" d="${a1}"/><path class="a" d="${a2}"/>` : ""}
  </g>`;
  const prop = props && PROPS[pose] ? PROPS[pose] : "";
  return `<g class="roo">${prop ? `<g class="die">${prop}</g>` : ""}<g class="die">${shape(false)}</g>${prop}${shape(true)}</g>`;
}

const ROO_CSS = `
.roo .f{fill:#15131E}.roo .b{fill:#221F2E}.roo .l{fill:#F3F1FA}.roo .i{fill:url(#iri);opacity:.9}.roo .c{fill:url(#iri);opacity:.8}.roo .e{fill:#0B0A10}.roo .hi{fill:#F3F1FA}
.roo .ln{fill:none;stroke:#0B0A10;stroke-width:3;stroke-linecap:round}.roo .lw{fill:none;stroke:#F3F1FA;stroke-width:3.4;stroke-linecap:round}.roo .m{fill:#0B0A10}
.roo .a{fill:none;stroke:#15131E;stroke-width:15;stroke-linecap:round}.roo .ao{fill:none;stroke:#15131E;stroke-width:15;stroke-linecap:round}
.roo .die *{fill:url(#iri)!important;stroke:url(#iri)!important;stroke-width:11px;stroke-linejoin:round;stroke-linecap:round}.roo .die .ao,.roo .die .bar,.roo .die .ln2{stroke-width:26px}
.roo .bag{fill:#D9D6E8}.roo .rim{fill:#8C86A8}.roo .hold{fill:#C9B8FF}.roo .bar{fill:#4A4566}.roo .zap{fill:url(#iri)}
.roo .ln2{fill:none;stroke:#A6EEE8;stroke-width:5;stroke-linecap:round;stroke-linejoin:round}.roo .zz{font:800 28px 'Barlow Condensed',sans-serif;fill:#EEF0FA}`;
const IRI = `<linearGradient id="iri" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#F4EEFF"/><stop offset=".28" stop-color="#C9B2FF"/><stop offset=".52" stop-color="#A6EEE8"/><stop offset=".76" stop-color="#FFC2E2"/><stop offset="1" stop-color="#F4EEFF"/></linearGradient>`;

function rnd(seed) {
  let s = seed;
  return () => ((s = (s * 16807) % 2147483647) - 1) / 2147483646;
}

const pts = (arr, x, y, s) => arr.map(([a, b]) => `${(x + a * s).toFixed(1)},${(y + b * s).toFixed(1)}`).join(" ");

function scene(state, w, h, opts = {}) {
  const p = SKY[state];
  const wide = w > h;
  const G = opts.ground ?? Math.round(h * (wide ? 0.56 : 0.47));
  const bw = wide ? w * 0.4 : w * 0.88;
  const s = bw / 1000;
  const bx = wide ? w * 0.4 : w * 0.3;
  const by = G - 600 * s;
  const r = rnd(7);
  const out = [];
  out.push(`<defs>${IRI}
    <linearGradient id="sky-${state}" x1="0" y1="0" x2="0" y2="1">${p.sky.map((c, i) => `<stop offset="${[0, 0.45, 0.8, 1][i]}" stop-color="${c}"/>`).join("")}</linearGradient>
    <radialGradient id="glow-${state}"><stop offset="0" stop-color="${p.glow || "transparent"}"/><stop offset="1" stop-color="transparent"/></radialGradient>
    <linearGradient id="fog-${state}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="rgba(170,178,215,0)"/><stop offset=".5" stop-color="rgba(170,178,215,.5)"/><stop offset="1" stop-color="rgba(170,178,215,0)"/></linearGradient>
    <radialGradient id="neb-${state}" cx=".25" cy=".2" r=".6"><stop offset="0" stop-color="rgba(160,120,255,.18)"/><stop offset=".5" stop-color="rgba(110,220,220,.06)"/><stop offset="1" stop-color="rgba(0,0,0,0)"/></radialGradient>
    <radialGradient id="dawn-${state}" cx=".5" cy="1" r=".7"><stop offset="0" stop-color="rgba(255,170,200,.55)"/><stop offset=".5" stop-color="rgba(190,140,255,.18)"/><stop offset="1" stop-color="rgba(0,0,0,0)"/></radialGradient>
    <filter id="speck-${state}" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency="1.4" numOctaves="1" seed="3"/><feColorMatrix type="matrix" values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 9 -5.6"/><feComposite in2="SourceGraphic" operator="in"/></filter>
  </defs>`);
  out.push(`<rect width="${w}" height="${G + 2}" fill="url(#sky-${state})"/>`);
  out.push(`<rect width="${w}" height="${G}" fill="url(#neb-${state})"/>`);
  if (state === "dawn") out.push(`<rect y="${G * 0.35}" width="${w}" height="${G * 0.65}" fill="url(#dawn-${state})"/>`);
  for (let i = 0; i < Math.round((wide ? 110 : 50) * p.stars); i++) out.push(`<circle cx="${(r() * w).toFixed(0)}" cy="${(r() * G * 0.7).toFixed(0)}" r="${(r() * 1.1 + 0.4).toFixed(1)}" fill="${["#EEF0FA", "#D9CCFF", "#C8F4F0", "#FFD6EC"][i % 4]}" opacity="${(r() * 0.6 + 0.3).toFixed(2)}"/>`);
  const lx = wide ? w * 0.62 : w * 0.84;
  const ly = wide ? h * 0.13 : h * 0.17;
  {
    out.push(`<circle cx="${lx}" cy="${ly}" r="${wide ? 150 : 90}" fill="url(#glow-${state})"/>`);
    out.push(`<circle cx="${lx}" cy="${ly}" r="${wide ? 30 : 19}" fill="${p.light}"/>`);
    out.push(`<circle cx="${lx - (wide ? 9 : 6)}" cy="${ly - 4}" r="${wide ? 5 : 3}" fill="#CFCDE0"/><circle cx="${lx + (wide ? 8 : 5)}" cy="${ly + 8}" r="${wide ? 3.5 : 2.2}" fill="#CFCDE0"/>`);
    if (state === "rain" || state === "fog") out.push(`<circle cx="${lx}" cy="${ly}" r="${wide ? 60 : 38}" fill="rgba(160,170,210,.18)"/>`);
  }
  const ridge = (yb, amp, c, seed) => {
    const q = rnd(seed);
    let d = `M0 ${G} L0 ${yb}`;
    for (let x = 0; x <= w + 60; x += wide ? 90 : 48) d += ` L${x} ${(yb - q() * amp).toFixed(0)}`;
    return `<path d="${d} L${w} ${G}Z" fill="${c}"/>`;
  };
  out.push(ridge(G - (wide ? 150 : 110), wide ? 70 : 40, p.ridge[0], 11));
  out.push(ridge(G - (wide ? 80 : 60), wide ? 50 : 30, p.ridge[1], 23));
  if (state === "fog") out.push(`<rect y="${G - (wide ? 200 : 140)}" width="${w}" height="${wide ? 200 : 150}" fill="url(#fog-${state})"/>`);

  const sb = wide ? 0.34 * s * 1000 / 400 : 0.42 * s * 1000 / 400;
  const sx = wide ? w * 0.82 : w * -0.06;
  const small = [[0, 300], [50, 130], [190, 50], [320, 100], [400, 300]];
  out.push(`<polygon points="${pts(small, sx, G - 300 * sb, sb)}" fill="${p.rock[2]}" stroke="${p.rock[3]}" stroke-width="2"/>`);
  out.push(`<polygon points="${pts([[50, 130], [190, 50], [220, 160], [100, 210]], sx, G - 300 * sb, sb)}" fill="${p.rock[0]}"/>`);

  const tx = wide ? w * 0.27 : w * 0.11;
  const ts = wide ? 1.25 : 0.82;
  out.push(`<path d="M${tx - 7 * ts} ${G} L${tx - 4 * ts} ${G - 120 * ts} L${tx + 4 * ts} ${G - 120 * ts} L${tx + 8 * ts} ${G}Z" fill="${p.rock[3]}"/>`);
  out.push(`<path d="M${tx} ${G - 70 * ts} L${tx + 34 * ts} ${G - 108 * ts}" stroke="${p.rock[3]}" stroke-width="${5 * ts}" stroke-linecap="round"/>`);
  for (const [cx, cy, cr, k] of [[-40, -150, 46, 0], [30, -170, 52, 1], [0, -205, 44, 0], [62, -128, 36, 0], [-62, -118, 32, 1], [-10, -130, 40, 1]])
    out.push(`<circle cx="${tx + cx * ts}" cy="${G + cy * ts}" r="${cr * ts}" fill="${p.canopy[k]}"/>`);

  const outline = [[0, 600], [40, 380], [130, 200], [300, 70], [480, 20], [640, 60], [800, 170], [920, 330], [1000, 600]];
  out.push(`<polygon points="${pts(outline, bx, by, s)}" fill="${p.rock[0]}" stroke="${p.rock[3]}" stroke-width="2.5" stroke-linejoin="round"/>`);
  out.push(`<polygon points="${pts([[130, 200], [300, 70], [480, 20], [520, 150], [330, 260]], bx, by, s)}" fill="${p.rock[1]}"/>`);
  out.push(`<polygon points="${pts([[520, 150], [480, 20], [640, 60], [700, 200]], bx, by, s)}" fill="${p.rock[1]}" opacity=".7"/>`);
  out.push(`<polygon points="${pts([[640, 60], [800, 170], [920, 330], [1000, 600], [760, 600], [700, 200]], bx, by, s)}" fill="${p.rock[2]}"/>`);
  out.push(`<polygon points="${pts([[40, 380], [220, 470], [520, 430], [760, 600], [0, 600]], bx, by, s)}" fill="${p.rock[3]}"/>`);
  out.push(`<polygon points="${pts(outline, bx, by, s)}" fill="#fff" opacity=".08" filter="url(#speck-${state})"/>`);
  out.push(`<polyline points="${pts([[480, 20], [520, 150], [500, 300], [560, 420]], bx, by, s)}" fill="none" stroke="${p.rock[3]}" stroke-width="2"/>`);
  out.push(`<polyline points="${pts([[40, 380], [130, 200], [300, 70], [480, 20], [640, 60], [800, 170]], bx, by, s)}" fill="none" stroke="url(#iri)" stroke-width="${wide ? 2.5 : 1.8}" stroke-linejoin="round" opacity="${state === "rain" ? 0.25 : 0.45}"/>`);
  for (const [hx, hy] of [[360, 200], [430, 320], [600, 250], [300, 360], [560, 120]]) {
    out.push(`<ellipse cx="${bx + hx * s}" cy="${by + hy * s}" rx="${16 * s}" ry="${9 * s}" fill="${p.rock[3]}"/>`);
    out.push(`<ellipse cx="${bx + (hx + 6) * s}" cy="${by + (hy - 9) * s}" rx="${12 * s}" ry="${5 * s}" fill="#E4E2F2" opacity="${state === "rain" ? 0.12 : 0.3}"/>`);
  }
  out.push(`<linearGradient id="gr-${state}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${p.ground}"/><stop offset="1" stop-color="${p.rock[3]}"/></linearGradient>`);
  out.push(`<rect y="${G}" width="${w}" height="${h - G}" fill="url(#gr-${state})"/>`);
  const g2 = rnd(53);
  let tufts = "", pebbles = "";
  for (let i = 0; i < (wide ? 70 : 28); i++) {
    const x = g2() * w, y = G + 8 + g2() ** 1.6 * (h - G) * 0.9, k = 0.7 + (y - G) / (h - G) * 1.6;
    tufts += `M${x.toFixed(0)} ${y.toFixed(0)} l${2 * k} ${-9 * k} l${2 * k} ${9 * k} l${2 * k} ${-6 * k} l${2 * k} ${6 * k}Z`;
    if (i % 2) pebbles += `<ellipse cx="${(g2() * w).toFixed(0)}" cy="${(G + 10 + g2() * (h - G) * 0.85).toFixed(0)}" rx="${(3 + g2() * 5) * k}" ry="${(2 + g2() * 2) * k}" fill="${p.rock[g2() > 0.5 ? 0 : 2]}"/>`;
  }
  out.push(pebbles, `<path d="${tufts}" fill="${p.canopy[1]}"/>`);
  const fy = G + (h - G) * 0.42, fh = h - fy;
  out.push(`<path d="M${-w * 0.05} ${h} L${-w * 0.02} ${fy + fh * 0.35} L${w * 0.08} ${fy + fh * 0.1} L${w * (wide ? 0.22 : 0.3)} ${fy + fh * 0.2} L${w * (wide ? 0.3 : 0.42)} ${fy + fh * 0.6} L${w * (wide ? 0.33 : 0.48)} ${h}Z" fill="${p.rock[2]}" stroke="${p.rock[3]}" stroke-width="2.5" stroke-linejoin="round"/>`);
  out.push(`<path d="M${w * 0.08} ${fy + fh * 0.1} L${w * (wide ? 0.22 : 0.3)} ${fy + fh * 0.2} L${w * (wide ? 0.16 : 0.2)} ${fy + fh * 0.4} L${w * 0.02} ${fy + fh * 0.36}Z" fill="${p.rock[0]}"/>`);
  out.push(`<path d="M${w * (wide ? 0.66 : 0.6)} ${h} L${w * (wide ? 0.7 : 0.66)} ${fy + fh * 0.4} L${w * 0.84} ${fy} L${w * 1.02} ${fy + fh * 0.15} L${w * 1.05} ${h}Z" fill="${p.rock[2]}" stroke="${p.rock[3]}" stroke-width="2.5" stroke-linejoin="round"/>`);
  out.push(`<path d="M${w * (wide ? 0.7 : 0.66)} ${fy + fh * 0.4} L${w * 0.84} ${fy} L${w * 0.9} ${fy + fh * 0.3} L${w * 0.78} ${fy + fh * 0.55}Z" fill="${p.rock[0]}"/>`);
  const slab = (x, y, ww, hh, c) => `<rect x="${x}" y="${y}" width="${ww}" height="${hh}" rx="${hh * 0.25}" fill="${c}" stroke="${p.rock[3]}" stroke-width="2"/>`;
  out.push(slab(bx + 60 * s, G + 6, 300 * s, 24 * s + 8, p.rock[0]));
  out.push(slab(bx + 420 * s, G + 12, 260 * s, 22 * s + 8, p.rock[2]));
  out.push(slab(w * 0.02, G + 14, w * 0.2, 20 * s + 8, p.rock[2]));
  const px = bx + 220 * s, pw = 330 * s, ph = 34 * s;
  out.push(`<rect x="${px}" y="${G - ph * 0.4}" width="${pw}" height="${ph}" rx="${ph * 0.3}" fill="#4E4680"/><rect x="${px}" y="${G - ph * 0.4}" width="${pw}" height="${ph * 0.42}" rx="${ph * 0.2}" fill="#272B58"/>`);
  const cbx = bx + 600 * s, cbs = s * 1.6;
  out.push(`<path d="M${cbx} ${G + 4} l${4 * cbs} ${-40 * cbs} h${36 * cbs} l${4 * cbs} ${40 * cbs}Z" fill="#5E4A8E"/><rect x="${cbx + 2 * cbs}" y="${G - 40 * cbs}" width="${40 * cbs}" height="${6 * cbs}" rx="${2 * cbs}" fill="#D8DAE8"/>`);

  if (state === "rain") {
    const q = rnd(31);
    let d = "";
    for (let i = 0; i < (wide ? 260 : 110); i++) {
      const x = q() * (w + 120), y = q() * h, len = 14 + q() * 16;
      d += `M${x.toFixed(0)} ${y.toFixed(0)} l${(-len * 0.28).toFixed(1)} ${len.toFixed(1)}`;
    }
    out.push(`<path d="${d}" stroke="rgba(190,205,245,.4)" stroke-width="1.3" stroke-linecap="round"/>`);
    out.push(`<rect width="${w}" height="${h}" fill="rgba(10,14,34,.18)"/>`);
  }
  if (state === "fog") {
    out.push(`<rect y="${G - (wide ? 90 : 60)}" width="${w}" height="${wide ? 170 : 110}" fill="url(#fog-${state})"/>`);
    out.push(`<rect y="${G * 0.35}" width="${w}" height="${wide ? 150 : 90}" fill="url(#fog-${state})" opacity=".7"/>`);
  }
  const pose = opts.pose || { dawn: "chalk", night: "look", rain: "shelter", fog: "sit" }[state];
  const rs = opts.rooScale || (wide ? 0.42 : 0.3);
  const rx = { chalk: cbx + 44 * cbs, shelter: bx + 60 * s, look: tx + 30 * ts, sit: tx + 26 * ts }[pose] ?? tx + 26 * ts;
  out.push(`<g transform="translate(${rx - 100 * rs} ${G + 6 - 246 * rs}) scale(${rs})">${roo(pose)}</g>`);
  if (pose === "chalk") out.push(`<g fill="#E4E2F2" opacity=".6">${[[-6, -16, 5], [-14, -26, 7], [-2, -32, 4], [-20, -12, 4]].map(([dx, dy, rr]) => `<circle cx="${rx - 100 * rs + 46 * rs + dx * rs * 2}" cy="${G + 6 - 246 * rs + 176 * rs + dy * rs * 2}" r="${rr * rs * 2}"/>`).join("")}</g>`);

  return `<svg class="scene" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" xmlns="http://www.w3.org/2000/svg"><style>${ROO_CSS}</style>${out.join("")}</svg>`;
}

function rooSvg(pose, size, opts = {}) {
  return `<svg class="roo-svg" viewBox="-16 -16 232 276" width="${size}" height="${size * 1.19}" xmlns="http://www.w3.org/2000/svg"><defs>${IRI}</defs><style>${ROO_CSS}</style>${opts.extra || ""}${roo(pose, opts.props ?? true)}</svg>`;
}
