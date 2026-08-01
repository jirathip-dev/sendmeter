import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const support = readFileSync(
  join(import.meta.dirname, "..", "..", "public", "support.html"),
  "utf8",
);

describe("public App Store support page", () => {
  it("provides real contact information and a privacy-policy path", () => {
    expect(support).toContain("<title>Sendmeter — Support</title>");
    expect(support).toContain('href="mailto:guyjrt10984@gmail.com"');
    expect(support).toContain('href="/privacy.html"');
  });

  it("documents the reviewer-accessible sensorless Force path", () => {
    expect(support).toContain("Train without sensor");
    expect(support).toContain("Live measured force requires a physical Tindeq Progressor");
  });
});
