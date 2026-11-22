const SKY = {
  dawn: { sky: ["#27304F", "#8E6F86", "#E9A98A", "#F5CFA0"], ridge: ["#5A5470", "#463F57"], rock: ["#6A6470", "#8C8590", "#4A4552", "#3A3542"], ground: "#4B4448", canopy: ["#3B4A46", "#4E5F57"], light: "#F6D7A6", glow: "rgba(246,200,150,.55)", lightest: "#F5CFA0" },
  golden: { sky: ["#6D8DB0", "#B9B3A0", "#E8B670", "#F3D29A"], ridge: ["#8C7D6E", "#6F6458"], rock: ["#8E7E6C", "#BCA488", "#625548", "#4E4339"], ground: "#6B5A47", canopy: ["#5C6A3C", "#7A7D3F"], light: "#FFE6A8", glow: "rgba(255,214,140,.6)", lightest: "#F3D29A" },
  night: { sky: ["#070B16", "#0E1628", "#1A2742", "#263552"], ridge: ["#141C2C", "#0F1522"], rock: ["#2A2E3B", "#3E4456", "#1C1F29", "#15171F"], ground: "#16181F", canopy: ["#121C1F", "#1A2729"], light: "#EEEBDD", glow: "rgba(220,226,240,.35)", lightest: "#EEEBDD" },
  rain: { sky: ["#3D4652", "#56616D", "#6E7A86", "#7F8A94"], ridge: ["#4E5761", "#434B55"], rock: ["#4C5257", "#646C72", "#373C41", "#2C3034"], ground: "#353A3D", canopy: ["#2F3D38", "#3D4D46"], light: null, glow: null, lightest: "#9AA4AE" },
  fog: { sky: ["#8E979C", "#A7AFB1", "#BEC4C3", "#CDD1CE"], ridge: ["#A3AAAC", "#959DA0"], rock: ["#6C7275", "#878D8F", "#575D60", "#4A4F52"], ground: "#5E6366", canopy: ["#58665F", "#66756D"], light: null, glow: null, lightest: "#DDE1DE" },
};

const FUR = { fur: "#8A6142", furDark: "#6E4B33", light: "#EBDCC2", inner: "#F1DDC6", cheek: "#E7A3A0", eye: "#1B1410" };

const ARM = {
  sit: ["M78 128 Q 84 146 94 152", "M122 128 Q 116 146 106 152"],
  rest: ["M78 128 Q 84 146 94 152", "M122 128 Q 116 146 106 152"],
  chalk: ["M76 126 Q 58 156 46 176", "M122 128 Q 116 146 106 152"],
  shelter: ["M74 132 Q 92 176 126 156", "M126 132 Q 112 170 80 160"],
  look: ["M78 128 Q 84 146 94 152", "M122 128 Q 116 146 106 152"],
  flash: ["M76 124 Q 50 96 34 58", "M124 124 Q 150 96 166 58"],
  send: ["M78 128 Q 84 146 94 152", "M124 124 Q 152 100 158 60"],
  pr: ["M76 126 Q 46 124 50 92", "M124 126 Q 154 124 150 92"],
  crimp: ["M78 128 Q 84 146 94 152", "M124 120 Q 140 80 146 34"],
  hang: ["M74 122 Q 56 70 52 10", "M126 122 Q 144 70 148 10"],
  dyno: ["M76 120 Q 62 70 58 6", "M124 120 Q 138 70 142 6"],
  fall: ["M78 120 Q 50 104 34 112", "M122 120 Q 150 104 166 112"],
};
const STRETCH = new Set(["hang", "dyno", "fall", "flash"]);
const HAPPY = new Set(["flash", "send", "pr", "dyno"]);

function roo(pose = "sit", hand = "headlamp") {
  const [a1, a2] = ARM[pose];
  const tilt = { look: -14, shelter: 8, fall: 18, rest: 6 }[pose] || 0;
  const ears = pose === "shelter" ? "rotate(-28 100 60)" : pose === "fall" ? "rotate(-12 100 60)" : "";
  const earsR = pose === "shelter" ? "rotate(28 100 60)" : pose === "fall" ? "rotate(16 100 60)" : "";
  const legs = STRETCH.has(pose)
    ? `<path class="f" d="M80 214 Q 74 232 70 246 L 92 246 Q 94 230 96 218Z"/><path class="f" d="M120 214 Q 126 232 130 246 L 108 246 Q 106 230 104 218Z"/>`
    : `<ellipse class="f" cx="78" cy="233" rx="28" ry="8"/><ellipse class="f" cx="124" cy="233" rx="28" ry="8"/>`;
  const body = { shelter: "translate(0 14) scale(1 .94)", dyno: "rotate(-8 100 140)", fall: "rotate(24 100 140)" }[pose] || "";
  const eyes = pose === "rest"
    ? `<path class="ln" d="M81 69 q5 4 10 0 M109 69 q5 4 10 0"/>`
    : `<circle class="e" cx="86" cy="68" r="3.6"/><circle class="e" cx="114" cy="68" r="3.6"/>`;
  const mouth = HAPPY.has(pose) ? `<path class="ln" d="M93 92 Q100 99 107 92"/>` : pose === "fall" ? `<ellipse class="e" cx="100" cy="94" rx="3" ry="4"/>` : "";
  const lamp = hand === "headlamp" ? `<path class="band" d="M67 62 Q100 50 133 62"/><circle class="glow" cx="100" cy="53" r="14"/><circle class="lamp" cx="100" cy="54" r="6"/>` : "";
  return `<g class="roo hand-${hand}">
    <g transform="${body}">
    <path class="f" d="M118 196 C 160 206 192 216 198 236 L 168 238 C 158 226 138 220 116 218Z"/>
    ${legs}
    <path class="f" d="M100 98 C 138 98 150 150 146 190 C 143 222 124 234 100 234 C 76 234 57 222 54 190 C 50 150 62 98 100 98Z"/>
    <ellipse class="l" cx="100" cy="182" rx="27" ry="38"/>
    <g transform="rotate(${tilt} 100 90)">
      <g transform="${ears}"><path class="f" d="M84 56 L 68 0 L 98 46Z"/><path class="i" d="M84 48 L 72 12 L 92 44Z"/></g>
      <g transform="${earsR}"><path class="f" d="M116 56 L 132 0 L 102 46Z"/><path class="i" d="M116 48 L 128 12 L 108 44Z"/></g>
      <ellipse class="f" cx="100" cy="72" rx="34" ry="30"/>
      <ellipse class="l" cx="100" cy="87" rx="16" ry="11"/>
      <ellipse class="e" cx="100" cy="80" rx="5" ry="3.5"/>
      ${eyes}${mouth}
      <ellipse class="c" cx="77" cy="84" rx="6" ry="4"/><ellipse class="c" cx="123" cy="84" rx="6" ry="4"/>
      ${lamp}
    </g>
    <path class="ao" d="${a1}"/><path class="ao" d="${a2}"/><path class="a" d="${a1}"/><path class="a" d="${a2}"/>
    </g>
  </g>`;
}

const ROO_CSS = `
.roo .f{fill:${FUR.fur}}.roo .l{fill:${FUR.light}}.roo .i{fill:${FUR.inner}}.roo .c{fill:${FUR.cheek}}.roo .e{fill:${FUR.eye}}
.roo .ln{fill:none;stroke:${FUR.eye};stroke-width:2.6;stroke-linecap:round}
.roo .a{fill:none;stroke:${FUR.fur};stroke-width:13;stroke-linecap:round}.roo .ao{fill:none;stroke:${FUR.furDark};stroke-width:17;stroke-linecap:round}
.hand-headlamp .f{fill:#6E4C34;stroke:#FFB85C;stroke-width:2.4;stroke-linejoin:round}.hand-headlamp .l,.hand-headlamp .i{fill:#E6CFAE}
.hand-headlamp .a{stroke:#6E4C34}.hand-headlamp .ao{stroke:#FFB85C;stroke-width:17.5}.hand-headlamp .c{fill:#D98C82}
.roo .band{fill:none;stroke:#23262F;stroke-width:6;stroke-linecap:round}.roo .lamp{fill:#FFE2A3}.roo .glow{fill:#FFB547;opacity:.35}`;

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
  out.push(`<defs>
    <linearGradient id="sky-${state}" x1="0" y1="0" x2="0" y2="1">${p.sky.map((c, i) => `<stop offset="${[0, 0.45, 0.8, 1][i]}" stop-color="${c}"/>`).join("")}</linearGradient>
    <radialGradient id="glow-${state}"><stop offset="0" stop-color="${p.glow || "transparent"}"/><stop offset="1" stop-color="transparent"/></radialGradient>
    <linearGradient id="fog-${state}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="rgba(232,235,232,0)"/><stop offset=".5" stop-color="rgba(232,235,232,.75)"/><stop offset="1" stop-color="rgba(232,235,232,0)"/></linearGradient>
    <filter id="speck-${state}" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency="1.4" numOctaves="1" seed="3"/><feColorMatrix type="matrix" values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 9 -5.6"/><feComposite in2="SourceGraphic" operator="in"/></filter>
  </defs>`);
  out.push(`<rect width="${w}" height="${G + 2}" fill="url(#sky-${state})"/>`);
  if (state === "night") for (let i = 0; i < (wide ? 90 : 40); i++) out.push(`<circle cx="${(r() * w).toFixed(0)}" cy="${(r() * G * 0.7).toFixed(0)}" r="${(r() * 1.1 + 0.4).toFixed(1)}" fill="#E8ECF5" opacity="${(r() * 0.6 + 0.3).toFixed(2)}"/>`);
  const lx = wide ? w * (state === "golden" ? 0.37 : 0.62) : w * 0.84;
  const ly = { dawn: G - 30, golden: wide ? G * 0.3 : G * 0.42, night: wide ? h * 0.13 : h * 0.17 }[state];
  if (p.light) {
    out.push(`<circle cx="${lx}" cy="${ly}" r="${wide ? 150 : 90}" fill="url(#glow-${state})"/>`);
    out.push(`<circle cx="${lx}" cy="${ly}" r="${wide ? 30 : 19}" fill="${p.light}"/>`);
    if (state === "night") out.push(`<circle cx="${lx - (wide ? 9 : 6)}" cy="${ly - 4}" r="${wide ? 5 : 3}" fill="#D8D4C4"/><circle cx="${lx + (wide ? 8 : 5)}" cy="${ly + 8}" r="${wide ? 3.5 : 2.2}" fill="#D8D4C4"/>`);
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
  for (const [hx, hy] of [[360, 200], [430, 320], [600, 250], [300, 360], [560, 120]]) {
    out.push(`<ellipse cx="${bx + hx * s}" cy="${by + hy * s}" rx="${16 * s}" ry="${9 * s}" fill="${p.rock[3]}"/>`);
    out.push(`<ellipse cx="${bx + (hx + 6) * s}" cy="${by + (hy - 9) * s}" rx="${12 * s}" ry="${5 * s}" fill="#F4F1EA" opacity="${state === "rain" ? 0.15 : 0.4}"/>`);
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
  out.push(`<rect x="${px}" y="${G - ph * 0.4}" width="${pw}" height="${ph}" rx="${ph * 0.3}" fill="#C9826D"/><rect x="${px}" y="${G - ph * 0.4}" width="${pw}" height="${ph * 0.42}" rx="${ph * 0.2}" fill="#2E3A5C"/>`);
  const cbx = bx + 600 * s, cbs = s * 1.6;
  out.push(`<path d="M${cbx} ${G + 4} l${4 * cbs} ${-40 * cbs} h${36 * cbs} l${4 * cbs} ${40 * cbs}Z" fill="#B9412E"/><rect x="${cbx + 2 * cbs}" y="${G - 40 * cbs}" width="${40 * cbs}" height="${6 * cbs}" rx="${2 * cbs}" fill="#E6DED2"/>`);

  if (state === "rain") {
    const q = rnd(31);
    let d = "";
    for (let i = 0; i < (wide ? 260 : 110); i++) {
      const x = q() * (w + 120), y = q() * h, len = 14 + q() * 16;
      d += `M${x.toFixed(0)} ${y.toFixed(0)} l${(-len * 0.28).toFixed(1)} ${len.toFixed(1)}`;
    }
    out.push(`<path d="${d}" stroke="rgba(214,226,238,.45)" stroke-width="1.3" stroke-linecap="round"/>`);
    out.push(`<rect width="${w}" height="${h}" fill="rgba(40,52,66,.12)"/>`);
  }
  if (state === "fog") {
    out.push(`<rect y="${G - (wide ? 90 : 60)}" width="${w}" height="${wide ? 170 : 110}" fill="url(#fog-${state})"/>`);
    out.push(`<rect y="${G * 0.35}" width="${w}" height="${wide ? 150 : 90}" fill="url(#fog-${state})" opacity=".7"/>`);
  }
  const pose = opts.pose || { dawn: "chalk", golden: "sit", night: "look", rain: "shelter", fog: "sit" }[state];
  const rs = opts.rooScale || (wide ? 0.42 : 0.3);
  const rx = { chalk: cbx + 44 * cbs, shelter: bx + 60 * s, look: tx + 30 * ts, sit: tx + 26 * ts }[pose] ?? tx + 26 * ts;
  out.push(`<g transform="translate(${rx - 100 * rs} ${G + 6 - 246 * rs}) scale(${rs})">${roo(pose, opts.hand || "headlamp")}</g>`);
  if (pose === "chalk") out.push(`<g fill="#F4F1EA" opacity=".7">${[[-6, -16, 5], [-14, -26, 7], [-2, -32, 4], [-20, -12, 4]].map(([dx, dy, rr]) => `<circle cx="${rx - 100 * rs + 46 * rs + dx * rs * 2}" cy="${G + 6 - 246 * rs + 176 * rs + dy * rs * 2}" r="${rr * rs * 2}"/>`).join("")}</g>`);

  return `<svg class="scene" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" xmlns="http://www.w3.org/2000/svg"><style>${ROO_CSS}</style>${out.join("")}</svg>`;
}

function rooSvg(pose, hand, size, extra = "") {
  return `<svg class="roo-svg" viewBox="-10 -10 220 260" width="${size}" height="${size * 1.18}" xmlns="http://www.w3.org/2000/svg"><style>${ROO_CSS}</style>${extra}${roo(pose, hand)}</svg>`;
}
