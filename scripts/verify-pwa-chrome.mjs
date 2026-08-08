import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const sourceManifestPath = join(root, "public", "manifest.json");
const builtManifestPath = join(root, "dist", "manifest.json");
const sourceManifest = readFileSync(sourceManifestPath, "utf8").trimEnd();
const builtManifest = readFileSync(builtManifestPath, "utf8").trimEnd();

if (sourceManifest !== builtManifest) {
  throw new Error("dist/manifest.json is not the authoritative public/manifest.json");
}

const builtIndex = readFileSync(join(root, "dist", "index.html"), "utf8");
const requiredThemeMetas = [
  '<meta name="theme-color" media="(prefers-color-scheme: light)" content="#F2F4F8" />',
  '<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#0E121B" />',
];
const themeMetas = Array.from(
  builtIndex.matchAll(/<meta\s+name="theme-color"[^>]*>/g),
  ([match]) => match,
);

if (
  themeMetas.length !== requiredThemeMetas.length ||
  requiredThemeMetas.some((meta) => !themeMetas.includes(meta))
) {
  throw new Error("dist/index.html has unexpected theme-color metas");
}

console.log("PWA chrome verified: manifest copied verbatim and light/dark metas shipped.");
