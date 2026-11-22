const dir = new URLSearchParams(location.search).get("d") || "golden";
document.documentElement.dataset.dir = dir;

const DEFS = `
<filter id="fuzz" x="-10%" y="-10%" width="120%" height="120%">
  <feTurbulence type="fractalNoise" baseFrequency=".75" numOctaves="2" seed="4" result="t"/>
  <feDisplacementMap in="SourceGraphic" in2="t" scale="5" xChannelSelector="R" yChannelSelector="G" result="d"/>
  <feTurbulence type="fractalNoise" baseFrequency="1.9" numOctaves="1" seed="9" result="g"/>
  <feColorMatrix in="g" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 4 0 0 0 -1.25" result="ga"/>
  <feComposite in="d" in2="ga" operator="in"/>
</filter>
<filter id="wobble"><feTurbulence type="fractalNoise" baseFrequency=".04" numOctaves="2" seed="2" result="t"/><feDisplacementMap in="SourceGraphic" in2="t" scale="4"/></filter>
<filter id="granite" x="0" y="0" width="1" height="1">
  <feTurbulence type="fractalNoise" baseFrequency="1.25" numOctaves="1" seed="7" result="n"/>
  <feColorMatrix in="n" type="matrix" values="0 0 0 0 .16 0 0 0 0 .16 0 0 0 0 .15 10 0 0 0 -6.3" result="dk"/>
  <feColorMatrix in="n" type="matrix" values="0 0 0 0 .96 0 0 0 0 .95 0 0 0 0 .9 0 10 0 0 -6.4" result="lt"/>
  <feComposite in="dk" in2="SourceGraphic" operator="atop" result="a"/>
  <feComposite in="lt" in2="a" operator="atop"/>
</filter>
<filter id="blur6"><feGaussianBlur stdDeviation="5 1.5"/></filter>
<filter id="blur12"><feGaussianBlur stdDeviation="10 2"/></filter>`;

const ARMS = {
  sit: [["M78 126 Q 82 144 92 150", 88, 151], ["M122 126 Q 118 144 108 150", 112, 151]],
  crimp: [["M80 126 Q 84 144 92 150", 89, 151], ["M120 122 Q 146 96 152 62", 152, 58]],
  dyno: [["M80 118 Q 66 76 62 34", 61, 30], ["M120 118 Q 134 76 138 34", 139, 30]],
};

function roo(pose = "sit", tag = "") {
  const [a1, a2] = ARMS[pose];
  const legs = pose === "dyno"
    ? `<path class="fur" d="M78 196 Q 74 228 80 262 Q 86 270 92 262 Q 94 230 96 204Z"/><path class="fur" d="M122 196 Q 126 228 120 262 Q 114 270 108 262 Q 106 230 104 204Z"/>`
    : `<ellipse class="fur" cx="66" cy="192" rx="22" ry="26"/><ellipse class="fur" cx="134" cy="192" rx="22" ry="26"/>
       <ellipse class="fur" cx="70" cy="219" rx="31" ry="11"/><ellipse class="fur" cx="130" cy="219" rx="31" ry="11"/>
       <path class="seam" d="M50 222 h10 M80 224 h8 M120 224 h8 M140 222 h10"/>`;
  const tail = pose === "dyno"
    ? `<path class="fur" d="M128 196 C 150 214 158 244 150 274 C 146 284 136 282 138 270 C 144 244 136 222 118 206Z"/>`
    : `<path class="fur" d="M140 198 C 172 206 196 194 194 160 C 193 148 180 148 179 160 C 177 182 160 190 134 186Z"/>`;
  return `<g class="roo ${tag}" filter="url(#fuzz)">
    ${tail}${legs}
    <path class="fur" d="M100 100 C 140 100 152 150 148 185 C 145 210 125 218 100 218 C 75 218 55 210 52 185 C 48 150 60 100 100 100Z"/>
    <ellipse class="light" cx="100" cy="170" rx="30" ry="38"/>
    <path class="fur" d="M74 54 C 62 32 58 10 64 -4 C 76 6 88 28 90 46Z"/><path class="inner" d="M75 46 C 67 30 65 14 67 4 C 75 14 82 28 84 42Z"/>
    <path class="fur" d="M126 54 C 138 32 142 10 136 -4 C 124 6 112 28 110 46Z"/><path class="inner" d="M125 46 C 133 30 135 14 133 4 C 125 14 118 28 116 42Z"/>
    <ellipse class="fur" cx="100" cy="74" rx="38" ry="34"/>
    <ellipse class="light" cx="100" cy="88" rx="19" ry="14"/>
    <ellipse class="cheek" cx="74" cy="86" rx="7" ry="5"/><ellipse class="cheek" cx="126" cy="86" rx="7" ry="5"/>
    <path class="arm" d="${a1}"/><path class="arm" d="${a2}"/>
    <circle class="fur" cx="${ARMS[pose][0][1]}" cy="${ARMS[pose][0][2]}" r="7.5"/><circle class="fur" cx="${ARMS[pose][1][1]}" cy="${ARMS[pose][1][2]}" r="7.5"/>
  </g>
  <g class="roo-face">
    <ellipse class="bead" cx="100" cy="81" rx="5.5" ry="4"/>
    <path class="mouth" d="M100 85 q0 6 -5 7 M100 85 q0 6 5 7"/>
    <circle class="bead" cx="85" cy="68" r="4.2"/><circle class="bead" cx="115" cy="68" r="4.2"/>
    <circle class="glint" cx="86.4" cy="66.6" r="1.3"/><circle class="glint" cx="116.4" cy="66.6" r="1.3"/>
  </g>`;
}

const at = (x, y, s, body, extra = "") => `<g transform="translate(${x} ${y}) scale(${s})" ${extra}>${body}</g>`;

function sky(w, h) {
  return `<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop class="sky-a" offset="0"/><stop class="sky-b" offset=".7"/><stop class="sky-c" offset="1"/></linearGradient></defs>
  <rect width="${w}" height="${h}" fill="url(#sky)"/>`;
}

const cloud = (x, y, s) => at(x, y, s, `<path class="doodle cloud" d="M10 30 C 0 30 0 16 12 16 C 12 4 30 2 34 12 C 40 4 56 8 54 20 C 64 20 64 32 54 32 Z"/>`);
const pine = (x, y, s) => at(x, y, s, `<path class="pine" d="M0 0 L -14 30 H -5 L -18 56 H -4 L -20 84 H 20 L 4 56 H 18 L 5 30 H 14 Z"/><rect class="trunk" x="-3" y="84" width="6" height="10"/>`);

function heroScene() {
  return `<svg viewBox="0 0 400 230" preserveAspectRatio="xMidYMid slice">${sky(400, 230)}
    <circle class="orb" cx="318" cy="56" r="24"/>${cloud(40, 30, .9)}${cloud(230, 14, .6)}
    <path class="hill" d="M0 150 C 60 120 120 132 170 118 C 230 102 300 128 400 112 V 230 H 0Z"/>
    ${pine(28, 86, .7)}${pine(52, 96, .55)}${pine(372, 74, .7)}
    <path class="ground" d="M0 196 C 100 188 300 190 400 194 V 230 H 0Z"/>
    <g class="tree"><path class="trunk" d="M66 200 C 70 170 62 150 70 120 L 78 120 C 74 150 82 172 80 200Z"/>
      <circle class="leaf" cx="58" cy="112" r="26"/><circle class="leaf" cx="88" cy="104" r="28"/><circle class="leaf" cx="74" cy="84" r="24"/></g>
    <path class="granite" d="M180 206 C 172 150 198 96 262 86 C 326 78 372 116 382 168 L 388 206Z" filter="url(#granite)"/>
    <path class="moss" d="M214 112 C 230 98 250 96 262 100 C 248 104 232 110 222 122Z M352 138 C 364 146 372 160 372 172 C 364 162 356 152 346 146Z"/>
    <ellipse class="shrub" cx="140" cy="200" rx="22" ry="12"/><ellipse class="shrub" cx="386" cy="204" rx="22" ry="12"/>
    <rect class="pad" x="190" y="196" width="150" height="20" rx="4"/><rect class="pad-b" x="190" y="204" width="150" height="5"/>
    <path class="bucket" d="M160 192 h20 l-3 20 h-14Z"/><path class="chalk" d="M160 192 h20 v4 h-20Z"/>
    ${at(206, 92, .52, roo("crimp"))}
  </svg>`;
}

function loadScene() {
  const ghost = (dx, dy, f, o) => at(390 + dx, 270 + dy, 1, roo("dyno"), `class="ghost" opacity="${o}" filter="url(#${f})"`);
  return `<svg viewBox="0 0 1000 1000" preserveAspectRatio="xMidYMid slice">${sky(1000, 1000)}
    <circle class="orb" cx="640" cy="250" r="44"/>${cloud(320, 230, 1.4)}${cloud(720, 330, 1)}
    <path class="hill" d="M0 640 C 160 600 300 620 420 590 C 560 560 700 610 1000 580 V 1000 H 0Z"/>
    ${pine(180, 520, 1.2)}${pine(230, 540, .9)}${pine(820, 500, 1.2)}${pine(870, 530, .9)}
    <path class="granite" d="M470 820 C 470 640 520 420 620 360 C 700 320 780 380 800 520 L 840 820Z" filter="url(#granite)"/>
    <path class="moss" d="M600 380 C 620 364 650 360 670 366 C 650 372 626 384 612 400Z"/>
    <path class="ground" d="M0 800 C 300 784 700 788 1000 796 V 1000 H 0Z"/>
    <rect class="pad" x="300" y="778" width="260" height="34" rx="6"/><rect class="pad-b" x="300" y="792" width="260" height="8"/>
    <path class="bucket" d="M262 768 h34 l-5 34 h-24Z"/><path class="chalk" d="M262 768 h34 v6 h-34Z"/>
    <ellipse class="shrub" cx="220" cy="804" rx="44" ry="22"/><ellipse class="shrub" cx="860" cy="810" rx="50" ry="24"/>
    <circle class="hold-crag" cx="552" cy="300" r="10"/>
    ${ghost(-34, 140, "blur12", .25)}${ghost(-18, 70, "blur6", .4)}
    ${at(390, 270, 1, roo("dyno"))}
    <path class="speed" d="M440 560 v60 M470 580 v80 M500 560 v70 M530 590 v50"/>
  </svg>`;
}

function iconArt() {
  return `<svg viewBox="0 0 100 100">${at(30, 22, .2, roo("dyno"))}
    <circle class="icon-hold" cx="42" cy="17" r="3.2"/><circle class="icon-hold" cx="58" cy="17" r="3.2"/></svg>`;
}

const petals = [0, 72, 144, 216, 288].map((a) => `<ellipse class="doodle petal" cx="20" cy="9" rx="6" ry="8.5" transform="rotate(${a} 20 20)"/>`).join("");
const doodle = (body, vb = "0 0 40 40") => () => `<svg class="doodle-svg" viewBox="${vb}" filter="url(#wobble)">${body}</svg>`;
const draw = {
  hero: heroScene, load: loadScene, icon: iconArt,
  sit: () => `<svg viewBox="40 -10 120 240">${roo("sit")}</svg>`,
  flower: doodle(`${petals}<circle class="doodle core" cx="20" cy="20" r="5"/>`),
  cloud: doodle(`<path class="doodle cloud" d="M8 30 C 0 30 0 18 10 18 C 10 8 24 6 27 14 C 32 8 42 12 40 21 C 46 22 45 31 38 31Z"/>`, "0 0 48 40"),
  sun: doodle(`<circle class="doodle core" cx="20" cy="20" r="8"/><path class="ray" d="M20 2v6M20 32v6M2 20h6M32 20h6M7 7l4 4M29 29l4 4M7 33l4-4M29 11l4-4"/>`),
};
document.body.insertAdjacentHTML("afterbegin", `<svg width="0" height="0" style="position:absolute">${DEFS}</svg>`);
for (const el of document.querySelectorAll("[data-art]")) el.innerHTML = draw[el.dataset.art]();

for (const svg of document.querySelectorAll("svg.spark")) {
  const v = svg.dataset.v.split(",").map(Number);
  const lo = Math.min(...v), hi = Math.max(...v);
  const pts = v.map((y, i) => `${(i / (v.length - 1)) * 100},${22 - ((y - lo) / (hi - lo || 1)) * 18}`);
  svg.setAttribute("viewBox", "0 0 100 26");
  svg.setAttribute("preserveAspectRatio", "none");
  svg.innerHTML = `<polyline points="${pts.join(" ")}" vector-effect="non-scaling-stroke"/>`;
}

for (const svg of document.querySelectorAll("svg.wall")) {
  const cols = 11, rows = 12, gap = 30;
  const lit = new Map(JSON.parse(svg.dataset.holds).map(([c, r, role]) => [`${c},${r}`, role]));
  svg.setAttribute("viewBox", `0 0 ${cols * gap} ${rows * gap}`);
  let out = "";
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
    const x = c * gap + gap / 2, y = r * gap + gap / 2;
    out += `<circle class="hold-dot" cx="${x}" cy="${y}" r="${3 + ((c * 7 + r * 5) % 4) * 1.6}"/>`;
    const role = lit.get(`${c},${r}`);
    if (role) out += `<circle class="hold ${role}" cx="${x}" cy="${y}" r="11" filter="url(#wobble)"/>`;
  }
  svg.innerHTML = out;
}
