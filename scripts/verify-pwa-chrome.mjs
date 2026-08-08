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
  { media: "(prefers-color-scheme: light)", content: "#F2F4F8" },
  { media: "(prefers-color-scheme: dark)", content: "#0E121B" },
];
const themeMetas = Array.from(
  builtIndex.matchAll(/<meta\s+name="theme-color"[^>]*>/g),
  ([match]) => ({
    media: match.match(/\bmedia\s*=\s*["']([^"']*)["']/i)?.[1] ?? null,
    content: match.match(/\bcontent\s*=\s*["']([^"']*)["']/i)?.[1] ?? null,
  }),
);

const bootstrap = builtIndex.match(
  /<script\b[^>]*data-theme-bootstrap[^>]*>([\s\S]*?)<\/script>/i,
)?.[1];
const bootstrapMarker = builtIndex.search(/<script\b[^>]*data-theme-bootstrap\b[^>]*>/i);
const moduleScriptMarker = builtIndex.search(
  /<script\b[^>]*type=["']module["'][^>]*>/i,
);
const bootstrapContract = [
  /localStorage/,
  /getItem\s*\(\s*["']theme["']\s*\)/,
  /matchMedia/,
  /data-theme/,
  /theme-color/,
  /not\s+all/,
];

if (
  themeMetas.length !== requiredThemeMetas.length ||
  requiredThemeMetas.some((required) =>
    !themeMetas.some(
      (actual) => actual.media === required.media && actual.content === required.content,
    ),
  ) ||
  !bootstrap ||
  bootstrapMarker < 0 ||
  moduleScriptMarker < 0 ||
  bootstrapMarker > moduleScriptMarker ||
  bootstrapContract.some((token) => !token.test(bootstrap))
) {
  throw new Error("dist/index.html has unexpected theme-color metas or bootstrap contract");
}

console.log("PWA chrome verified: manifest copied verbatim and light/dark metas shipped.");
