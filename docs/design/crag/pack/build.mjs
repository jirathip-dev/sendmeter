import { readFileSync, writeFileSync } from "node:fs";
import { master, rigJson, POSES, COLOURS } from "./roo.mjs";
import { ICONS, icon } from "./icons.mjs";

const here = (f) => new URL(f, import.meta.url);
const css = readFileSync(here("crag.css"), "utf8");
const root = css.match(/:root\s*\{([^}]*)\}/)[1];
const tokens = Object.fromEntries([...root.matchAll(/--([\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]));

writeFileSync(here("roo-master.svg"), master());
writeFileSync(here("rig.json"), JSON.stringify(rigJson(), null, 2) + "\n");
writeFileSync(here("poses.json"), JSON.stringify(Object.fromEntries(Object.entries(POSES).map(([k, p]) => [k, { label: p.label, view: p.view || "side", angles: p.angles, lift: p.y || 0, props: p.props || [], eyes: p.eyes || "open" }])), null, 2) + "\n");
writeFileSync(here("tokens.json"), JSON.stringify({ blocks: tokens, roo: COLOURS }, null, 2) + "\n");
for (const ic of ICONS) writeFileSync(here(`icons/${ic.id}.svg`), icon(ic.id, 1024, { radius: false }).replace(/<svg /, '<svg xmlns="http://www.w3.org/2000/svg" '));
console.log("wrote roo-master.svg rig.json poses.json tokens.json and", ICONS.length, "icons");
