import { roo } from "./roo.mjs";

export const ICONS = [
  { id: "profile", label: "Profile", pose: "bust", box: [-48, -162, 140, 140], bg: "moon" },
  { id: "crimp", label: "Crimp", pose: "crimp", box: [-44, -150, 125, 125], bg: "moon" },
  { id: "chalk", label: "Chalk-up", pose: "chalk", box: [-84, -168, 176, 176], bg: "moon" },
  { id: "dyno", label: "Dyno", pose: "dyno", box: [-36, -136, 112, 112], bg: "stars" },
  { id: "shoe", label: "Shoe", pose: "stand", box: [-16, 2, 70, 70], bg: "foothold" },
  { id: "peek", label: "Peek", pose: "stand", box: [-50, -146, 130, 130], bg: "lip" },
  { id: "rest", label: "Rest", pose: "rest", box: [-50, -128, 150, 150], bg: "crescent" },
  { id: "send", label: "Send", pose: "send", box: [-38, -160, 125, 125], bg: "moon" },
];

const BG = {
  moon: `<circle cx="700" cy="330" r="200" fill="#E9EAF6" opacity=".95"/><circle cx="630" cy="290" r="34" fill="#CFD1E6"/>`,
  crescent: `<path d="M760 170 A220 220 0 1 0 760 610 A170 170 0 1 1 760 170Z" fill="#E9EAF6"/>`,
  stars: [...Array(26)].map((_, i) => `<circle cx="${(i * 397) % 1024}" cy="${(i * 211) % 700}" r="${3 + (i % 3) * 2}" fill="#EEF0FA" opacity="${0.4 + (i % 4) * 0.15}"/>`).join("") + `<circle cx="820" cy="210" r="90" fill="#E9EAF6"/>`,
  crag: `<path d="M-20 1044 L-20 420 L180 300 L420 340 L520 520 L460 760 L560 1044Z" fill="#1E2244" stroke="#06071A" stroke-width="14"/><path d="M180 300 L240 520 L120 700M420 340 L340 600" stroke="#06071A" stroke-width="10" fill="none"/><path d="M-20 420 L180 300 L420 340" stroke="#C9C6F0" stroke-width="10" fill="none"/><circle cx="820" cy="220" r="80" fill="#E9EAF6"/>`,
  foothold: `<circle cx="800" cy="220" r="90" fill="#E9EAF6"/><path d="M-20 1044 L-20 760 L300 700 L700 740 L1044 700 L1044 1044Z" fill="#1E2244" stroke="#06071A" stroke-width="14"/><path d="M300 700 L700 740" stroke="#C9C6F0" stroke-width="10"/>`,
  lip: `<circle cx="760" cy="300" r="170" fill="#E9EAF6"/>`,
};
const FRONT = {
  lip: `<path d="M-20 1044 L-20 760 L240 690 L560 720 L800 680 L1044 740 L1044 1044Z" fill="#1E2244" stroke="#06071A" stroke-width="16" stroke-linejoin="round"/><path d="M-20 760 L240 690 L560 720 L800 680 L1044 740" stroke="#C9C6F0" stroke-width="10" fill="none"/><path d="M240 690 L300 880 L220 1044M800 680 L740 900" stroke="#06071A" stroke-width="10" fill="none"/>`,
};

export function icon(id, size = 180, { radius = true } = {}) {
  const ic = ICONS.find((i) => i.id === id) || ICONS[0];
  const inner = roo(ic.pose, { size: 1024, box: ic.box, rim: ic.box[2] / 90 }).replace(/<svg [^>]*?(viewBox="[^"]*")[^>]*>/, `<svg x="0" y="0" width="1024" height="1024" $1 preserveAspectRatio="xMidYMid slice">`);
  const r = radius ? 226 : 0;
  return `<svg viewBox="0 0 1024 1024" width="${size}" height="${size}" role="img" aria-label="App icon, ${ic.label}">
    <defs><clipPath id="ic-${id}-${size}"><rect width="1024" height="1024" rx="${r}"/></clipPath><linearGradient id="ib-${id}-${size}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#151A45"/><stop offset="1" stop-color="#060820"/></linearGradient></defs>
    <g clip-path="url(#ic-${id}-${size})"><rect width="1024" height="1024" fill="url(#ib-${id}-${size})"/>${BG[ic.bg] || ""}${inner}${FRONT[ic.bg] || ""}</g></svg>`;
}
