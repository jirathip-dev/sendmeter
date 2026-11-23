export const COLOURS = {
  fur: "#1A1C30",
  far: "#111222",
  limb: "#23263F",
  ear: "#4A4E78",
  muzzle: "#ECEEF8",
  spot: "#D3D7EC",
  nose: "#0A0A12",
  shoe: "#E4E6F2",
  rubber: "#2A2D45",
  strap: "#A99CF0",
  rim: "#7471B0",
};

const C = COLOURS;
const RIM = 5;

const shapes = {
  body: (v) =>
    v === "front" || v === "back"
      ? `<ellipse cx="0" cy="-30" rx="30" ry="36"/>`
      : `<path d="M-24 0 C-32 -24 -24 -58 2 -64 C24 -68 34 -48 32 -26 C30 -6 20 6 2 8 C-12 9 -20 6 -24 0Z"/>`,
  head: (v) => {
    if (v === "back") return `<circle cx="0" cy="-30" r="32"/>`;
    if (v === "front")
      return `<circle cx="0" cy="-30" r="32"/>
      <g data-detail=""><ellipse cx="0" cy="-17" rx="15" ry="11" fill="${C.muzzle}"/><ellipse cx="0" cy="-22" rx="5.4" ry="4" fill="${C.nose}"/>
      <path d="M-5 -14 Q0 -10 5 -14" fill="none" stroke="${C.nose}" stroke-width="1.8" stroke-linecap="round"/>
      <circle data-eye="" cx="-12" cy="-36" r="3.8" fill="${C.nose}"/><circle data-eye="" cx="12" cy="-36" r="3.8" fill="${C.nose}"/>
      <circle data-glint="" cx="-11" cy="-37.4" r="1.2" fill="#fff"/><circle data-glint="" cx="13" cy="-37.4" r="1.2" fill="#fff"/>
      <circle cx="-22" cy="-20" r="4.6" fill="${C.spot}"/><circle cx="22" cy="-20" r="4.6" fill="${C.spot}"/></g>`;
    return `<circle cx="0" cy="-30" r="32"/><ellipse cx="26" cy="-20" rx="17" ry="14"/>
      <g data-detail=""><ellipse cx="30" cy="-20" rx="13" ry="11" fill="${C.muzzle}"/>
      <ellipse cx="40" cy="-24" rx="5" ry="4" fill="${C.nose}"/>
      <path d="M28 -13 Q33 -9 38 -13" fill="none" stroke="${C.nose}" stroke-width="1.8" stroke-linecap="round"/>
      <circle data-eye="" cx="14" cy="-38" r="3.8" fill="${C.nose}"/><circle data-glint="" cx="15" cy="-39.4" r="1.2" fill="#fff"/>
      <circle cx="4" cy="-14" r="4.6" fill="${C.spot}"/><circle cx="-6" cy="-22" r="3.4" fill="${C.spot}"/></g>`;
  },
  ear: () => `<ellipse cx="0" cy="-20" rx="13" ry="21"/><g data-detail=""><ellipse cx="0" cy="-19" rx="7" ry="13" fill="${C.ear}"/></g>`,
  arm: () => `<path d="M-7 0 L-7.5 34 A8.5 8.5 0 0 0 9.5 34 L7 0 A7 7 0 0 0 -7 0Z"/>`,
  thigh: () => `<ellipse cx="6" cy="12" rx="19" ry="22" transform="rotate(-20 6 12)"/>`,
  shin: () => `<path d="M-6 0 L-5 16 A5 5 0 0 0 5 16 L6 0 A6 6 0 0 0 -6 0Z"/>`,
  shoe: (v) => v === "front" || v === "back"
    ? `<path d="M-11 2 C-12 -10 12 -10 11 2 C11 10 -11 10 -11 2Z" fill="${C.shoe}"/><g data-detail=""><path d="M-10 4 C-8 10 8 10 10 4" fill="none" stroke="${C.rubber}" stroke-width="3.4" stroke-linecap="round"/><path d="M-8 -3 L8 -3" stroke="${C.strap}" stroke-width="3" stroke-linecap="round"/></g>`
    : `<g transform="scale(1.2)"><path d="M-6 -8 C-10 -2 -9 8 -2 10 L24 10 C31 10 34 5 30 1 C25 -4 14 -4 8 -9 C3 -12 -3 -12 -6 -8Z" fill="${C.shoe}"/>
    <g data-detail=""><path d="M-7 4 C-7 9 -4 10.5 -1 10.5 L25 10.5 C30 10.5 33 7 32 3" fill="none" stroke="${C.rubber}" stroke-width="3.4" stroke-linecap="round"/>
    <path d="M4 -8 L10 4" stroke="${C.strap}" stroke-width="3.2" stroke-linecap="round"/></g></g>`,
  tail: () => `<path d="M4 -16 C-18 -14 -40 0 -54 18 C-58 24 -53 30 -47 26 C-32 16 -16 12 4 12Z"/>`,
};

const PROPS = {
  bag: `<g transform="translate(-8 4)"><path d="M-11 0 C-12 14 -10 22 0 22 C10 22 12 14 11 0Z" fill="${C.shoe}"/><rect x="-12" y="-4" width="24" height="6" rx="3" fill="${C.strap}"/><circle cx="-3" cy="-10" r="4" fill="${C.spot}" opacity=".6"/><circle cx="5" cy="-14" r="3" fill="${C.spot}" opacity=".45"/></g>`,
  hold: `<path d="M-16 -2 C-14 -12 12 -14 18 -4 C20 2 12 6 0 6 C-10 6 -18 4 -16 -2Z" fill="#5A5F7E"/>`,
  bar: `<rect x="-60" y="-8" width="120" height="10" rx="5" fill="#5A5F7E"/>`,
  bolt: `<path d="M2 -26 L-10 0 L0 0 L-4 22 L12 -6 L2 -6 L8 -26Z" fill="${C.muzzle}"/>`,
  star: `<path d="M0 -14 L4 -4 L14 -3 L6 4 L9 14 L0 8 L-9 14 L-6 4 L-14 -3 L-4 -4Z" fill="${C.muzzle}"/>`,
  dust: `<g fill="${C.spot}" opacity=".7"><circle cx="-10" cy="-6" r="3"/><circle cx="8" cy="-10" r="2.4"/><circle cx="2" cy="-18" r="2"/><circle cx="14" cy="0" r="1.8"/><circle cx="-4" cy="-24" r="1.4"/></g>`,
  zz: `<g fill="none" stroke="${C.spot}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h10L0 10h10"/><path d="M14 -16h7l-7 7h7" stroke-width="1.8"/></g>`,
};

export const PARTS = ["body", "head", "earFar", "earNear", "armFar", "armNear", "thighFar", "shinFar", "shoeFar", "thighNear", "shinNear", "shoeNear", "tail"];

const RIG = {
  id: "body", shape: "body", at: [0, 0],
  kids: [
    { id: "tail", shape: "tail", at: [-18, -4], behind: true },
    { id: "thighFar", shape: "thigh", at: [-4, -12], far: true, behind: true,
      kids: [{ id: "shinFar", shape: "shin", at: [12, 28], far: true, behind: true, kids: [{ id: "shoeFar", shape: "shoe", at: [0, 20] }] }] },
    { id: "armFar", shape: "arm", at: [12, -46], far: true, behind: true },
    { id: "head", shape: "head", at: [8, -56],
      kids: [
        { id: "earFar", shape: "ear", at: [-12, -54], far: true, behind: true },
        { id: "earNear", shape: "ear", at: [4, -58] },
      ] },
    { id: "thighNear", shape: "thigh", at: [2, -10],
      kids: [{ id: "shinNear", shape: "shin", at: [12, 28], behind: true, kids: [{ id: "shoeNear", shape: "shoe", at: [0, 20] }] }] },
    { id: "armNear", shape: "arm", at: [18, -44] },
  ],
};

const FRONT = {
  id: "body", shape: "body", at: [0, 0],
  kids: [
    { id: "tail", shape: "tail", at: [-8, -6], behind: true },
    { id: "thighFar", shape: "thigh", at: [-16, -10], kids: [{ id: "shinFar", shape: "shin", at: [4, 28], behind: true, kids: [{ id: "shoeFar", shape: "shoe", at: [0, 20] }] }] },
    { id: "thighNear", shape: "thigh", at: [16, -10], kids: [{ id: "shinNear", shape: "shin", at: [4, 28], behind: true, kids: [{ id: "shoeNear", shape: "shoe", at: [0, 20] }] }] },
    { id: "armFar", shape: "arm", at: [-26, -48] },
    { id: "armNear", shape: "arm", at: [26, -48] },
    { id: "head", shape: "head", at: [0, -58], kids: [
      { id: "earFar", shape: "ear", at: [-16, -52] },
      { id: "earNear", shape: "ear", at: [16, -52] },
    ] },
  ],
};

const Z = { body: 0, head: 0, earFar: -16, earNear: 8, armFar: 0, armNear: 0, thighFar: 0, shinFar: 0, shoeFar: 0, thighNear: 0, shinNear: 0, shoeNear: 0, tail: 0 };
const pose = (o) => ({ ...Z, ...o });

export const POSES = {
  stand: { label: "Stand", angles: pose({ body: 4, armFar: 14, armNear: -8, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }) },
  bust: { label: "Bust", angles: pose({ body: 4, head: -4, armFar: 14, armNear: 34, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }) },
  sit: { label: "Sit", angles: pose({ body: -2, armFar: -30, armNear: -40, thighFar: -70, shinFar: 92, shoeFar: -24, thighNear: -64, shinNear: 84, shoeNear: -20, tail: -14 }), y: 23 },
  chalk: { label: "Chalk-up", angles: pose({ body: 2, head: 14, armFar: -40, armNear: 20, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }),
    props: [{ name: "bag", on: "body", at: [-30, -14] }, { name: "dust", on: "armNear", at: [0, 42] }] },
  crimp: { label: "Crimp", angles: pose({ body: -6, head: -22, armFar: -150, armNear: -128, thighFar: -40, shinFar: 60, shoeFar: -40, thighNear: 20, shinNear: 10, shoeNear: -10, tail: 20 }),
    props: [{ name: "hold", on: "armNear", at: [0, 46] }] },
  dyno: { label: "Dyno", angles: pose({ body: 18, head: -34, earFar: -40, earNear: -20, armFar: -150, armNear: -122, thighFar: 30, shinFar: 10, shoeFar: 18, thighNear: 0, shinNear: 40, shoeNear: 10, tail: 34 }) },
  hang: { label: "Hang", view: "front", angles: pose({ earFar: -12, earNear: 12, thighFar: 4, shinFar: -6, shoeFar: 0, thighNear: -6, shinNear: 6, shoeNear: 0, tail: 8, armFar: 160, armNear: -160 }), y: 19,
    props: [{ name: "bar", on: "body", at: [0, -88] }] },
  flash: { label: "Flash", view: "front", angles: pose({ earFar: -12, earNear: 12, thighFar: 6, shinFar: -6, shoeFar: 0, thighNear: -6, shinNear: 6, shoeNear: 0, tail: 0, armFar: 150, armNear: -150 }), y: 19,
    props: [{ name: "bolt", on: "body", at: [0, -146] }] },
  send: { label: "Send", angles: pose({ body: 2, head: -10, armFar: 18, armNear: -132, thighFar: 4, shinFar: 10, shoeFar: -14, thighNear: -6, shinNear: 18, shoeNear: -12, tail: -6 }) },
  fall: { label: "Fall", angles: pose({ body: -58, head: 20, earFar: 40, earNear: 56, armFar: -120, armNear: -70, thighFar: -60, shinFar: 40, shoeFar: -10, thighNear: 30, shinNear: -10, shoeNear: 0, tail: 40 }) },
  rest: { label: "Rest", angles: pose({ body: -6, head: 36, earFar: 30, earNear: 44, armFar: -20, armNear: -30, thighFar: -74, shinFar: 96, shoeFar: -24, thighNear: -68, shinNear: 88, shoeNear: -20, tail: -14 }), y: 23,
    props: [{ name: "zz", on: "head", at: [36, -64] }], eyes: "shut" },
  pr: { label: "PR", view: "front", angles: pose({ earFar: -12, earNear: 12, thighFar: 6, shinFar: -6, shoeFar: 0, thighNear: -6, shinNear: 6, shoeNear: 0, tail: 0, armFar: 150, armNear: -150 }), y: 19,
    props: [{ name: "star", on: "body", at: [0, -150] }] },
  shelter: { label: "Shelter", angles: pose({ body: 20, head: 30, earFar: 60, earNear: 70, armFar: -40, armNear: -60, thighFar: -70, shinFar: 100, shoeFar: -24, thighNear: -64, shinNear: 94, shoeNear: -20, tail: -20 }), y: -3 },
  moon: { label: "Moon-watch", angles: pose({ body: -6, head: -30, earFar: -24, earNear: -8, armFar: -30, armNear: -40, thighFar: -70, shinFar: 92, shoeFar: -24, thighNear: -64, shinNear: 84, shoeNear: -20, tail: -14 }), y: 18 },
  front: { label: "Front", view: "front", angles: pose({ earFar: -10, earNear: 10, armFar: 18, armNear: -18, thighFar: 6, shinFar: -6, shoeFar: 0, thighNear: -6, shinNear: 6, shoeNear: 0, tail: 0 }), y: 19 },
  back: { label: "Back", view: "back", angles: pose({ earFar: -10, earNear: 10, armFar: 18, armNear: -18, thighFar: 6, shinFar: -6, shoeFar: 0, thighNear: -6, shinNear: 6, shoeNear: 0, tail: -60 }), y: 13 },
};

function draw(node, p, pass, view) {
  const a = p.angles[node.id] || 0;
  const tf = `translate(${node.at[0]} ${node.at[1]}) rotate(${a})`;
  let shape = shapes[node.shape](view);
  if (node.shape === "head" && p.eyes === "shut") shape = shape.replace(/<circle data-glint=""[^>]*\/>/g, "").replace(/<circle data-eye="" cx="(-?[\d.]+)" cy="(-?[\d.]+)"[^>]*\/>/g, (_, x, y) => `<path d="M${+x - 4} ${y} Q${x} ${+y + 3.5} ${+x + 4} ${y}" fill="none" stroke="${C.nose}" stroke-width="2" stroke-linecap="round"/>`);
  if (view === "back" && node.shape === "head") shape = shapes.head("back");
  const fill = node.far ? C.far : node.id === "armNear" ? C.limb : C.fur;
  const body = pass === "fill"
    ? `<g fill="${fill}"${node.id === "armNear" ? ` stroke="${C.rim}" stroke-width="2"` : ""}>${shape}</g>`
    : `<g>${shape.replace(/<g data-detail="">[\s\S]*?<\/g>/g, "")}</g>`;
  const kids = node.kids || [];
  const order = view === "back" ? (k) => !k.behind : (k) => k.behind;
  const back = kids.filter(order).map((k) => draw(k, p, pass, view)).join("");
  const front = kids.filter((k) => !order(k)).map((k) => draw(k, p, pass, view)).join("");
  const props = pass === "fill" ? (p.props || []).filter((q) => q.on === node.id).map((q) => `<g transform="translate(${q.at[0]} ${q.at[1]}) rotate(${-(a)})">${PROPS[q.name]}</g>`).join("") : "";
  return `<g data-part="${node.id}" transform="${tf}">${back}${body}${front}${props}</g>`;
}

export function roo(name = "stand", { size = 160, flip = false, edge = true, rim = RIM, box = [-120, -200, 240, 300], label } = {}) {
  const p = POSES[name] || POSES.stand;
  const view = p.view || "side";
  const rig = view === "side" ? RIG : FRONT;
  const ry = p.y || 0;
  const wrap = (inner) => `<g transform="translate(0 ${ry})${flip ? " scale(-1 1)" : ""}">${inner}</g>`;
  const outline = edge ? `<g fill="${C.rim}" stroke="${C.rim}" stroke-width="${rim}" stroke-linejoin="round">${wrap(draw(rig, p, "edge", view))}</g>` : "";
  const [x, y, w, h] = box;
  return `<svg viewBox="${x} ${y} ${w} ${h}" width="${size}" height="${(size * h) / w}" role="img" aria-label="${label || "Roo, " + p.label}">
    ${outline}${wrap(draw(rig, p, "fill", view))}</svg>`;
}

export function master() {
  const part = (k) => `<g id="part-${k}" fill="${C.fur}">${shapes[k]("side")}</g>`;
  const front = ["body", "head"].map((k) => `<g id="part-${k}-front" fill="${C.fur}">${shapes[k]("front")}</g>`).join("");
  const props = Object.entries(PROPS).map(([k, v]) => `<g id="prop-${k}">${v}</g>`).join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-120 -200 240 300">
<title>Roo kit master: crag pack</title>
<desc>Flat fills, no outline inside. Every part is drawn at its pivot (0,0). rig.json gives each part's parent, attach point and draw order; poses.json gives the joint angles. On dark backgrounds the whole posed silhouette gets one thin flat rim (${C.rim}, ${RIM}px stroke behind the fills).</desc>
<defs>
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
