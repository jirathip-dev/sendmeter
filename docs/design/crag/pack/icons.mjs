import { roo, foot, where } from "./roo.mjs";
import { rock } from "./scene.mjs";

const RIM = "#B3AEF5";
const LIP = "#D9D6FA";

export const ICONS = [
  { id: "profile", label: "Profile", pose: "bust", box: [-44, -156, 132, 132], moon: [790, 250, 120], rock: "peak" },
  { id: "crimp", label: "Crimp", pose: "crimp", box: [-10, -132, 104, 104], moon: [860, 150, 80], rock: "face" },
  { id: "chalk", label: "Chalk-up", pose: "chalk", box: [-52, -126, 148, 148], moon: [820, 200, 95], rock: "peak" },
  { id: "dyno", label: "Dyno", pose: "dyno", box: [-60, -160, 180, 180], moon: [150, 160, 80], rock: "faceL", jug: true, tilt: -34 },
  { id: "shoe", label: "Shoe", rock: "face", moon: [840, 170, 90] },
  { id: "peek", label: "Peek", pose: "stand", box: [-50, -146, 130, 130], moon: [790, 260, 130], rock: "lip" },
  { id: "rest", label: "Rest", pose: "deadhang", box: [-84, -150, 168, 168], moon: [900, 120, 70], rock: "face" },
  { id: "send", label: "Send", pose: "topout", box: [-38, -136, 128, 128], moon: [820, 190, 95], rock: "top" },
  { id: "tongue", label: "Tongue", pose: "tongue", box: [-52, -126, 120, 120], moon: [150, 150, 70], rock: "faceL" },
];

const ROCK = {
  face: "M-40 1064 L-40 -40 L480 -40 C620 20 720 100 800 200 C900 320 980 380 1064 400 L1064 1064Z",
  faceL: "M1064 1064 L1064 -40 L540 -40 C400 20 300 100 224 200 C124 320 44 380 -40 400 L-40 1064Z",
  peak: "M-40 1064 L-40 520 C20 400 160 280 330 260 C480 244 600 320 660 440 C700 520 720 640 780 760 C840 840 960 860 1064 870 L1064 1064Z",
  lip: "M-40 1064 L-40 720 C120 660 300 640 520 660 C720 680 900 640 1064 690 L1064 1064Z",
};
const RIMS = {
  face: "M480 -40 C620 20 720 100 800 200 C900 320 980 380 1064 400",
  faceL: "M540 -40 C400 20 300 100 224 200 C124 320 44 380 -40 400",
  peak: "M-40 520 C20 400 160 280 330 260 C480 244 600 320 660 440",
  lip: "M-40 720 C120 660 300 640 520 660 C720 680 900 640 1064 690",
};
const CRACKS = {
  face: ["M300 -40 C260 160 340 320 280 520 C240 660 300 820 260 1064"],
  faceL: ["M720 -40 C760 160 690 320 750 520 C790 660 720 820 770 1064"],
  peak: ["M360 270 C330 420 400 560 350 720 C320 840 360 960 340 1064"],
  lip: ["M300 650 C290 760 330 880 300 1064", "M800 668 C820 780 780 900 810 1064"],
};
const SHADE = {
  face: ["M-40 760 C200 700 500 780 1064 720 L1064 1064 L-40 1064Z"],
  faceL: ["M-40 720 C400 780 700 700 1064 760 L1064 1064 L-40 1064Z"],
  peak: ["M-40 860 C300 800 600 900 1064 940 L1064 1064 L-40 1064Z"],
  lip: ["M-40 900 C300 860 700 900 1064 880 L1064 1064 L-40 1064Z"],
};

function stars(seed) {
  return [...Array(9)].map((_, i) => `<circle cx="${(i * 397 + seed * 131) % 1024}" cy="${(i * 211 + seed * 53) % 420}" r="${7 + (i % 3) * 3}" fill="#EEF0FA" opacity="${0.45 + (i % 3) * 0.15}"/>`).join("");
}

function moon([x, y, r]) {
  return `<circle cx="${x}" cy="${y}" r="${r * 1.7}" fill="#E9E6FF" opacity=".07"/><circle cx="${x}" cy="${y}" r="${r}" fill="#E9EAF6"/><circle cx="${x - r * 0.32}" cy="${y - r * 0.2}" r="${r * 0.2}" fill="#CFD1E6"/>`;
}

const STONE = { tone: [18, 14], blur: 40, line: 3, rimColor: LIP, rimWidth: 12 };
const boulder = (key, d, uid) =>
  rock(`r-${uid}`, d, [-40, -40, 1064, 1064], 0, { ...STONE, rim: [RIMS[key]], cracks: CRACKS[key], shade: SHADE[key], pockets: key.startsWith("face") ? [[key === "face" ? 150 : 870, 880, 4], [key === "face" ? 860 : 170, 620, 3.2]] : key === "peak" ? [[520, 560, 3]] : [] });

function topRock(ic, uid) {
  const [bx, by, bw] = ic.box, k = 1024 / bw;
  const [, hy] = where(ic.pose, "armNear", [0, 38]);
  const y = Math.round((hy - 4 - by) * k);
  const edge = `M-40 ${y + 40} C200 ${y + 4} 600 ${y - 10} 1064 ${y + 30}`;
  return rock(`r-${uid}`, `${edge} L1064 1064 L-40 1064Z`, [-40, y - 40, 1064, 1064], 0, { ...STONE, rim: [edge], cracks: [`M640 ${y} C610 ${y + 160} 680 ${y + 300} 630 1064`], shade: [`M-40 ${y + 380} C400 ${y + 320} 700 ${y + 400} 1064 ${y + 360} L1064 1064 L-40 1064Z`] });
}

function jug(ic) {
  const [hx, hy] = where(ic.pose, "armNear", [0, 38]);
  const at = [hx + 22, hy - 26];
  const lines = [0, 1, 2].map((i) => `<path d="M${hx - 30 - i * 8} ${hy + 18 + i * 14} l-30 18" stroke="${LIP}" stroke-width="3.4" stroke-linecap="round" opacity=".7"/>`).join("");
  return { under: `<g transform="translate(${at[0]} ${at[1]}) rotate(${-ic.tilt}) scale(1.15)">${shapeJug}</g>${lines}` };
}
const shapeJug = `<path d="M-26 -6 C-26 -20 26 -20 26 -6 C26 6 16 12 0 12 C-16 12 -26 6 -26 -6Z" fill="#7D82A8" stroke="#06071A" stroke-width="2"/><path d="M-16 -4 C-10 -9 10 -9 16 -4" fill="none" stroke="#06071A" stroke-width="5" stroke-linecap="round"/><path d="M-20 -13 C-10 -17 10 -17 20 -13" fill="none" stroke="#C9CCE6" stroke-width="2" stroke-linecap="round"/>`;

function slap(ic) {
  const [hx, hy] = where(ic.pose, "armNear", [0, 34]);
  return { over: [[-26, -14], [-6, -24], [16, -20]].map(([dx, dy]) => `<path d="M${hx + 8 + dx * 0.55} ${hy - 8 + dy * 0.45} l${dx * 0.5} ${dy * 0.5}" stroke="${LIP}" stroke-width="3" stroke-linecap="round"/>`).join("") };
}

function shoeCrop() {
  const hold = `<g transform="translate(40 33) scale(.8)"><path d="M-14 4 C-14 -4 -6 -7 4 -7 C12 -7 16 -2 16 4 C16 9 -14 9 -14 4Z" fill="#7D82A8" stroke="#06071A" stroke-width="1.4"/><path d="M-11 -2 C-6 -6 6 -6.5 13 -3" fill="none" stroke="#C9CCE6" stroke-width="1.4" stroke-linecap="round"/></g>`;
  return `<svg x="0" y="0" width="1024" height="1024" viewBox="-30 -34 88 88" preserveAspectRatio="xMidYMid slice">${hold}${foot({ shin: -14, shoe: 8, rim: 1.6 }).replaceAll('fill="#7471B0" stroke="#7471B0"', `fill="${RIM}" stroke="${RIM}"`)}</svg>`;
}

export function icon(id, size = 180, { radius = true } = {}) {
  const ic = ICONS.find((i) => i.id === id) || ICONS[0];
  const uid = `${id}-${size}`;
  let inner;
  if (ic.id === "shoe") inner = shoeCrop();
  else {
    const extra = ic.jug ? jug(ic) : ic.id === "send" ? slap(ic) : {};
    inner = roo(ic.pose, { size: 1024, box: ic.box, rim: ic.box[2] / 46, rimColor: RIM, ...extra })
      .replace(/<svg [^>]*?(viewBox="[^"]*")[^>]*>/, `<svg x="0" y="0" width="1024" height="1024" $1 preserveAspectRatio="xMidYMid slice">`);
  }
  const back = ic.rock === "top" ? topRock(ic, uid) : boulder(ic.rock, ROCK[ic.rock], uid);
  const lipFront = ic.rock === "lip";
  if (ic.tilt) inner = `<g transform="rotate(${ic.tilt} 512 512)">${inner}</g>`;
  const r = radius ? 226 : 0;
  return `<svg viewBox="0 0 1024 1024" width="${size}" height="${size}" role="img" aria-label="App icon, ${ic.label}">
    <defs><clipPath id="ic-${uid}"><rect width="1024" height="1024" rx="${r}"/></clipPath><linearGradient id="ib-${uid}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#181D4E"/><stop offset="1" stop-color="#080A26"/></linearGradient></defs>
    <g clip-path="url(#ic-${uid})"><rect width="1024" height="1024" fill="url(#ib-${uid})"/>${stars(id.length)}${moon(ic.moon)}${lipFront ? "" : back}${inner}${lipFront ? back : ""}</g></svg>`;
}
