// Renders assets/app-icon-source.jpg into every icon slot the project needs.
// The source is already 1:1, so "cover" resizes without cropping — the full
// frame is preserved in every slot.
// Run: node scripts/generate-icons.mjs
import sharp from "sharp";
import { mkdirSync } from "node:fs";

const SRC = new URL("../assets/app-icon-source.jpg", import.meta.url).pathname;

// Icons stay opaque — App Store marketing icons reject alpha.
const BACKGROUND = "#0a0c10";

// The two 1024 app icons stay full-colour: fidelity beats bytes there, and they
// ship inside the binary rather than over the wire. Everything in public/ is
// served to browsers, so it gets palette-quantised (dithered, so the gradients
// don't band) — ~4x smaller at no visible cost.
const LOSSLESS_PNG = { compressionLevel: 9, adaptiveFiltering: true };
const LEAN_PNG = { compressionLevel: 9, effort: 10, palette: true, quality: 100 };

const targets = [
  { out: "ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png", size: 1024, png: LOSSLESS_PNG },
  { out: "ios/App/SendLogWatch Watch App/Assets.xcassets/AppIcon.appiconset/icon1024.png", size: 1024, png: LOSSLESS_PNG },
  // PWA icons (manifest.json)
  { out: "public/icon-512.png", size: 512, png: LEAN_PNG },
  { out: "public/icon-192.png", size: 192, png: LEAN_PNG },
  { out: "public/apple-touch-icon.png", size: 180, png: LEAN_PNG },
  // Browser tab (index.html)
  { out: "public/favicon.png", size: 96, png: LEAN_PNG },
  { out: "public/favicon-32.png", size: 32, png: LEAN_PNG },
];

for (const t of targets) {
  mkdirSync(t.out.split("/").slice(0, -1).join("/"), { recursive: true });
  await sharp(SRC)
    .resize(t.size, t.size, { kernel: "lanczos3", fit: "cover" })
    .flatten({ background: BACKGROUND })
    .png(t.png)
    .toFile(t.out);
  console.log("wrote", t.out);
}
