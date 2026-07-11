// Renders scripts/icon.svg into every icon slot the project needs.
// Run: node scripts/generate-icons.mjs
import sharp from "sharp";
import { mkdirSync } from "node:fs";

const SVG = new URL("./icon.svg", import.meta.url).pathname;

const targets = [
  // App Store marketing icons must be opaque (no alpha)
  { out: "ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png", size: 1024, alpha: false },
  { out: "watch/SendLogWatch/Assets.xcassets/AppIcon.appiconset/icon1024.png", size: 1024, alpha: false },
  // PWA icons (manifest.json)
  { out: "public/icon-192.png", size: 192, alpha: false },
  { out: "public/icon-512.png", size: 512, alpha: false },
  { out: "public/apple-touch-icon.png", size: 180, alpha: false },
];

for (const t of targets) {
  mkdirSync(t.out.split("/").slice(0, -1).join("/"), { recursive: true });
  let img = sharp(SVG, { density: 300 }).resize(t.size, t.size);
  if (!t.alpha) img = img.flatten({ background: "#0a0c10" });
  await img.png().toFile(t.out);
  console.log("wrote", t.out);
}
