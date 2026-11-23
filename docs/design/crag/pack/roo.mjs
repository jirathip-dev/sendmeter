export const COLOURS = {
  fur: "#12131F",
  far: "#1E2033",
  limb: "#1D2038",
  seam: "#4A4E6E",
  ear: "#3C3F5C",
  muzzle: "#ECEEF8",
  spot: "#D3D7EC",
  nose: "#0A0A12",
  shoe: "#E4E6F2",
  rubber: "#1A1C2C",
  strap: "#A99CF0",
  cutline: "#07081A",
  iri: ["#C2A8FF", "#8FE6E0", "#FFB3DC"],
};

const C = COLOURS;
const EDGE = 7;

const shapes = {
  body: (v) =>
    v === "front" || v === "back"
      ? `<ellipse cx="0" cy="-34" rx="25" ry="37"/>`
      : `<path d="M-20 -6 C-27 -30 -20 -62 2 -72 C18 -76 26 -60 24 -40 C23 -20 18 -2 4 4 C-6 7 -16 3 -20 -6Z"/>`,
  head: (v) => {
    if (v === "back") return `<ellipse cx="0" cy="-18" rx="22" ry="20"/>`;
    if (v === "front")
      return `<ellipse cx="0" cy="-18" rx="22" ry="20"/>
      <g data-detail=""><ellipse cx="0" cy="-8" rx="12" ry="9" fill="${C.muzzle}"/><ellipse cx="0" cy="-12" rx="4.6" ry="3.4" fill="${C.nose}"/>
      <path d="M-4 -5 Q0 -2 4 -5" fill="none" stroke="${C.nose}" stroke-width="1.6" stroke-linecap="round"/>
      <circle cx="-10" cy="-23" r="3.2" fill="${C.nose}" stroke="${C.spot}" stroke-width="1.2"/><circle cx="10" cy="-23" r="3.2" fill="${C.nose}" stroke="${C.spot}" stroke-width="1.2"/>
      <circle cx="-9" cy="-24" r="1" fill="#fff"/><circle cx="11" cy="-24" r="1" fill="#fff"/>
      <circle cx="-15" cy="-11" r="3.6" fill="${C.spot}"/><circle cx="15" cy="-11" r="3.6" fill="${C.spot}"/></g>`;
    return `<path d="M-20 -16 C-20 -32 -6 -40 6 -38 C18 -36 24 -28 28 -20 C34 -18 38 -14 36 -8 C34 -2 26 0 18 0 C4 2 -20 0 -20 -16Z"/>
      <g data-detail=""><path d="M16 -20 C26 -22 36 -16 35 -9 C34 -2 24 -1 16 -2 C12 -6 12 -16 16 -20Z" fill="${C.muzzle}"/>
      <ellipse cx="33" cy="-13" rx="4" ry="3.2" fill="${C.nose}"/>
      <path d="M23 -6 Q27 -3 31 -5" fill="none" stroke="${C.nose}" stroke-width="1.6" stroke-linecap="round"/>
      <circle cx="10" cy="-22" r="3.2" fill="${C.nose}" stroke="${C.spot}" stroke-width="1.2"/><circle cx="11" cy="-23" r="1" fill="#fff"/>
      <circle cx="2" cy="-8" r="3.6" fill="${C.spot}"/><circle cx="-5" cy="-14" r="2.4" fill="${C.spot}"/></g>`;
  },
  ear: () => `<ellipse cx="0" cy="-17" rx="9" ry="17"/><g data-detail=""><ellipse cx="0" cy="-16" rx="4.6" ry="11" fill="${C.ear}"/></g>`,
  arm: () => `<path d="M-6 0 L-5.5 48 A7 7 0 1 0 6 50 L6 0 A6 6 0 0 0 -6 0Z"/>`,
  thigh: () => `<ellipse cx="4" cy="16" rx="15" ry="23" transform="rotate(-14 4 16)"/>`,
  shin: () => `<path d="M-5.5 0 L-4.5 40 A4.8 4.8 0 0 0 4.5 40 L5.5 0 A5.5 5.5 0 0 0 -5.5 0Z"/>`,
  shoe: () =>
    `<path d="M-6 -8 C-10 -2 -9 8 -2 10 L24 10 C31 10 34 5 30 1 C25 -4 14 -4 8 -9 C3 -12 -3 -12 -6 -8Z" fill="${C.shoe}"/>
    <g data-detail=""><path d="M-7 4 C-7 9 -4 10.5 -1 10.5 L25 10.5 C30 10.5 33 7 32 3" fill="none" stroke="${C.rubber}" stroke-width="3.4" stroke-linecap="round"/>
    <path d="M4 -8 L10 4" stroke="${C.strap}" stroke-width="3.2" stroke-linecap="round"/></g>`,
  tail: () => `<path d="M4 -14 C-20 -12 -44 4 -62 26 C-67 32 -62 38 -55 33 C-38 20 -18 14 4 13Z"/>`,
};

const PROPS = {
  bag: `<g transform="translate(-8 4)"><path d="M-11 0 C-12 14 -10 22 0 22 C10 22 12 14 11 0Z" fill="${C.shoe}"/><rect x="-12" y="-4" width="24" height="6" rx="3" fill="${C.strap}"/><circle cx="-3" cy="-10" r="4" fill="${C.spot}" opacity=".6"/><circle cx="5" cy="-14" r="3" fill="${C.spot}" opacity=".45"/></g>`,
  hold: `<path d="M-16 -2 C-14 -12 12 -14 18 -4 C20 2 12 6 0 6 C-10 6 -18 4 -16 -2Z" fill="#5A5F7E" stroke="${C.cutline}" stroke-width="1.5"/>`,
  bar: `<rect x="-60" y="-8" width="120" height="10" rx="5" fill="#5A5F7E" stroke="${C.cutline}" stroke-width="1.5"/>`,
  bolt: `<path d="M2 -26 L-10 0 L0 0 L-4 22 L12 -6 L2 -6 L8 -26Z" fill="${C.muzzle}"/>`,
  star: `<path d="M0 -14 L4 -4 L14 -3 L6 4 L9 14 L0 8 L-9 14 L-6 4 L-14 -3 L-4 -4Z" fill="${C.muzzle}"/>`,
  dust: `<g fill="${C.spot}" opacity=".7"><circle cx="-10" cy="-6" r="3"/><circle cx="8" cy="-10" r="2.4"/><circle cx="2" cy="-18" r="2"/><circle cx="14" cy="0" r="1.8"/><circle cx="-4" cy="-24" r="1.4"/></g>`,
  zz: `<g fill="none" stroke="${C.spot}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h10L0 10h10"/><path d="M14 -16h7l-7 7h7" stroke-width="1.8"/></g>`,
};

export const PARTS = ["body", "head", "earFar", "earNear", "armFar", "armNear", "thighFar", "shinFar", "shoeFar", "thighNear", "shinNear", "shoeNear", "tail"];

const RIG = {
  id: "body", shape: "body", at: [0, 0],
  kids: [
    { id: "tail", shape: "tail", at: [-14, -2], behind: true },
    { id: "thighFar", shape: "thigh", at: [-2, -8], far: true, behind: true,
      kids: [{ id: "shinFar", shape: "shin", at: [10, 32], far: true, behind: true, kids: [{ id: "shoeFar", shape: "shoe", at: [0, 42] }] }] },
    { id: "armFar", shape: "arm", at: [10, -58], far: true, behind: true },
    { id: "head", shape: "head", at: [6, -66],
      kids: [
        { id: "earFar", shape: "ear", at: [-6, -32], far: true, behind: true },
        { id: "earNear", shape: "ear", at: [6, -34] },
      ] },
    { id: "thighNear", shape: "thigh", at: [2, -6],
      kids: [{ id: "shinNear", shape: "shin", at: [10, 32], behind: true, kids: [{ id: "shoeNear", shape: "shoe", at: [0, 42] }] }] },
    { id: "armNear", shape: "arm", at: [14, -56] },
  ],
};

const FRONT = {
  id: "body", shape: "body", at: [0, 0],
  kids: [
    { id: "tail", shape: "tail", at: [-6, -4], behind: true },
    { id: "thighFar", shape: "thigh", at: [-12, -8], far: true, kids: [{ id: "shinFar", shape: "shin", at: [6, 32], behind: true, kids: [{ id: "shoeFar", shape: "shoe", at: [0, 42] }] }] },
    { id: "thighNear", shape: "thigh", at: [12, -8], kids: [{ id: "shinNear", shape: "shin", at: [6, 32], behind: true, kids: [{ id: "shoeNear", shape: "shoe", at: [0, 42] }] }] },
    { id: "armFar", shape: "arm", at: [-20, -56] },
    { id: "armNear", shape: "arm", at: [20, -56] },
    { id: "head", shape: "head", at: [0, -68], kids: [
      { id: "earFar", shape: "ear", at: [-11, -33] },
      { id: "earNear", shape: "ear", at: [11, -33] },
    ] },
  ],
};

const Z = { body: 0, head: 0, earFar: -14, earNear: 10, armFar: 0, armNear: 0, thighFar: 0, shinFar: 0, shoeFar: 0, thighNear: 0, shinNear: 0, shoeNear: 0, tail: 0 };
const pose = (o) => ({ ...Z, ...o });

export const POSES = {
  stand: { label: "Stand", angles: pose({ body: 4, armFar: 14, armNear: -8, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }) },
  bust: { label: "Bust", angles: pose({ body: 4, head: -4, armFar: 14, armNear: 34, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }) },
  sit: { label: "Sit", angles: pose({ body: -2, armFar: -30, armNear: -40, thighFar: -70, shinFar: 92, shoeFar: -24, thighNear: -64, shinNear: 84, shoeNear: -20, tail: -14 }), y: -34 },
  chalk: { label: "Chalk-up", angles: pose({ body: 2, head: 14, armFar: -40, armNear: 20, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }),
    props: [{ name: "bag", on: "body", at: [-24, -18] }, { name: "dust", on: "armNear", at: [0, 52] }] },
  crimp: { label: "Crimp", angles: pose({ body: -8, head: -18, armFar: -200, armNear: -150, thighFar: -40, shinFar: 60, shoeFar: -40, thighNear: 20, shinNear: 10, shoeNear: -10, tail: 20 }),
    props: [{ name: "hold", on: "armNear", at: [0, 56] }] },
  dyno: { label: "Dyno", angles: pose({ body: 16, head: -26, earFar: -30, earNear: -6, armFar: -205, armNear: -160, thighFar: 26, shinFar: 6, shoeFar: 18, thighNear: -2, shinNear: 36, shoeNear: 10, tail: 30 }) },
  hang: { label: "Hang", angles: pose({ body: 0, head: 8, armFar: -195, armNear: -165, thighFar: 8, shinFar: 0, shoeFar: 10, thighNear: -6, shinNear: 10, shoeNear: 6, tail: 28 }),
    props: [{ name: "bar", on: "armNear", at: [0, 55] }] },
  flash: { label: "Flash", angles: pose({ body: 0, head: -8, armFar: -215, armNear: -150, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }),
    props: [{ name: "bolt", on: "armNear", at: [0, 70] }] },
  send: { label: "Send", angles: pose({ body: 2, head: -6, armFar: 18, armNear: -155, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }) },
  fall: { label: "Fall", angles: pose({ body: -58, head: 20, earFar: 40, earNear: 56, armFar: -120, armNear: -70, thighFar: -60, shinFar: 40, shoeFar: -10, thighNear: 30, shinNear: -10, shoeNear: 0, tail: 40 }) },
  rest: { label: "Rest", angles: pose({ body: -6, head: 36, earFar: 30, earNear: 44, armFar: -20, armNear: -30, thighFar: -74, shinFar: 96, shoeFar: -24, thighNear: -68, shinNear: 88, shoeNear: -20, tail: -14 }), y: -34,
    props: [{ name: "zz", on: "head", at: [30, -50] }], eyes: "shut" },
  pr: { label: "PR", angles: pose({ body: 0, head: -10, armFar: -215, armNear: -150, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }),
    props: [{ name: "star", on: "head", at: [6, -70] }] },
  shelter: { label: "Shelter", angles: pose({ body: 20, head: 30, earFar: 60, earNear: 70, armFar: -40, armNear: -60, thighFar: -70, shinFar: 100, shoeFar: -24, thighNear: -64, shinNear: 94, shoeNear: -20, tail: -20 }), y: -30 },
  moon: { label: "Moon-watch", angles: pose({ body: -6, head: -30, earFar: -24, earNear: -8, armFar: -30, armNear: -40, thighFar: -70, shinFar: 92, shoeFar: -24, thighNear: -64, shinNear: 84, shoeNear: -20, tail: -14 }), y: -34 },
  front: { label: "Front", view: "front", angles: pose({ earFar: -10, earNear: 10, armFar: 18, armNear: -18, thighFar: 6, shinFar: -6, shoeFar: 90, thighNear: -6, shinNear: 6, shoeNear: 90, tail: 0 }) },
  back: { label: "Back", view: "back", angles: pose({ earFar: -10, earNear: 10, armFar: 18, armNear: -18, thighFar: 6, shinFar: -6, shoeFar: 90, thighNear: -6, shinNear: 6, shoeNear: 90, tail: -60 }) },
};

const ids = (() => { let n = 0; return () => `r${++n}`; })();

function draw(node, p, pass, view) {
  const a = p.angles[node.id] || 0;
  const tf = `translate(${node.at[0]} ${node.at[1]}) rotate(${a})`;
  let shape = shapes[node.shape](view);
  if (node.shape === "head" && p.eyes === "shut") shape = shape.replace(/<circle cx="(\d+)" cy="-2[23]" r="3.2"[^>]*\/>(<circle[^>]*r="1"[^>]*\/>)?/g, (_, x) => `<path d="M${+x - 3.5} -22 Q${x} -19 ${+x + 3.5} -22" fill="none" stroke="${C.spot}" stroke-width="1.6" stroke-linecap="round"/>`);
  if (view === "back" && node.shape === "head") shape = shapes.head("back");
  const fill = node.far ? C.far : node.id === "armNear" ? C.limb : C.fur;
  const body = pass === "fill"
    ? `<g fill="${fill}" stroke="${C.seam}" stroke-width="1.3">${shape}</g>`
    : `<g>${shape.replace(/<g data-detail="">[\s\S]*?<\/g>/g, "")}</g>`;
  const kids = node.kids || [];
  const order = view === "back" ? (k) => !k.behind : (k) => k.behind;
  const back = kids.filter(order).map((k) => draw(k, p, pass, view)).join("");
  const front = kids.filter((k) => !order(k)).map((k) => draw(k, p, pass, view)).join("");
  const props = pass === "fill" ? (p.props || []).filter((q) => q.on === node.id).map((q) => `<g transform="translate(${q.at[0]} ${q.at[1]}) rotate(${-(a)})">${PROPS[q.name]}</g>`).join("") : "";
  return `<g data-part="${node.id}" transform="${tf}">${back}${body}${front}${props}</g>`;
}

export function roo(name = "stand", { size = 160, flip = false, edge = true, box = [-120, -200, 240, 300], label } = {}) {
  const p = POSES[name] || POSES.stand;
  const view = p.view || "side";
  const rig = view === "side" ? RIG : FRONT;
  const id = ids();
  const ry = p.y || 0;
  const wrap = (inner) => `<g transform="translate(0 ${ry})${flip ? " scale(-1 1)" : ""}">${inner}</g>`;
  const passes = edge
    ? `<g fill="${C.cutline}" stroke="${C.cutline}" stroke-width="${EDGE * 2 + 3}" stroke-linejoin="round">${wrap(draw(rig, p, "edge", view))}</g>
       <g fill="url(#${id})" stroke="url(#${id})" stroke-width="${EDGE * 2}" stroke-linejoin="round">${wrap(draw(rig, p, "edge", view))}</g>`
    : "";
  const [x, y, w, h] = box;
  return `<svg viewBox="${x} ${y} ${w} ${h}" width="${size}" height="${(size * h) / w}" role="img" aria-label="${label || "Roo, " + p.label}">
    <defs><linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="-80" y1="-180" x2="80" y2="40">
      <stop offset="0" stop-color="${C.iri[0]}"/><stop offset=".35" stop-color="${C.iri[1]}"/><stop offset=".7" stop-color="${C.iri[2]}"/><stop offset="1" stop-color="${C.iri[0]}"/></linearGradient></defs>
    ${passes}${wrap(draw(rig, p, "fill", view))}${(p.props || []).length && !edge ? "" : ""}</svg>`;
}

export function master() {
  const id = "iri";
  const part = (k) => `<g id="part-${k}" fill="${C.fur}" stroke="${C.seam}" stroke-width="1.3">${shapes[k]("side")}</g>`;
  const front = ["body", "head"].map((k) => `<g id="part-${k}-front" fill="${C.fur}" stroke="${C.seam}" stroke-width="1.3">${shapes[k]("front")}</g>`).join("");
  const props = Object.entries(PROPS).map(([k, v]) => `<g id="prop-${k}">${v}</g>`).join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-120 -200 240 300">
<title>Roo kit master: crag pack</title>
<desc>Every part is drawn at its pivot (0,0). rig.json gives each part's parent, attach point and draw order; poses.json gives the joint angles. The iridescent edge is the whole posed silhouette stroked twice: cutline ${EDGE * 2 + 3}px, then the ${id} gradient ${EDGE * 2}px.</desc>
<defs><linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="-80" y1="-180" x2="80" y2="40"><stop offset="0" stop-color="${C.iri[0]}"/><stop offset=".35" stop-color="${C.iri[1]}"/><stop offset=".7" stop-color="${C.iri[2]}"/><stop offset="1" stop-color="${C.iri[0]}"/></linearGradient>
${["body", "head", "ear", "arm", "thigh", "shin", "shoe", "tail"].map(part).join("\n")}
${front}
${props}</defs>
</svg>
`;
}

export function rigJson() {
  const flat = (n, parent, out) => { out.push({ part: n.id, shape: n.shape, parent, at: n.at, behind: !!n.behind, far: !!n.far }); (n.kids || []).forEach((k) => flat(k, n.id, out)); return out; };
  return { side: flat(RIG, null, []), front: flat(FRONT, null, []) };
}
