import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import path from "node:path";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PW_CORE);
const dir = path.dirname(new URL(import.meta.url).pathname);
const browser = await chromium.launch({ executablePath: process.env.CHROME });
for (const page of process.argv.slice(2)) {
  for (const [w, h] of [[390, 844], [1440, 900]]) {
    const p = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
    await p.goto(pathToFileURL(path.join(dir, `${page}.html`)).href);
    await p.screenshot({ path: path.join(dir, "png", `${page}-${w}.png`), fullPage: true });
    await p.close();
  }
}
await browser.close();
