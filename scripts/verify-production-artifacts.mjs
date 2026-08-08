import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const dist = join(root, "dist");
const textExtensions = /\.(?:css|html|js|json|mjs)$/i;
const forbidden = [
  /dev@sendmeter\.test/i,
  /devpassword/i,
  /LOCAL_DEV_(?:EMAIL|PASSWORD)/,
  /VITE_DEV_AUTO_LOGIN/i,
  /devAuth/i,
  /Local dev auto-login/i,
  /UI-QA-LAB/i,
  /ui-qa/i,
  /uiqa-/i,
];

function textFiles(directory) {
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...textFiles(path));
    else if (textExtensions.test(entry.name)) files.push(path);
  }
  return files;
}

if (!statSync(dist).isDirectory()) {
  throw new Error("dist/ is missing; run vite build before checking production artifacts");
}

const violations = textFiles(dist).flatMap((path) => {
  const source = readFileSync(path, "utf8");
  return forbidden
    .filter((pattern) => pattern.test(source))
    .map((pattern) => `${path}: ${pattern}`);
});

if (violations.length > 0) {
  throw new Error(
    [
      "Production artifact contract failed: DEV-only lab/auth markers leaked into dist/.",
      ...violations,
    ].join("\n"),
  );
}

console.log("Production artifact contract verified: no DEV-only lab/auth markers in dist/.");
