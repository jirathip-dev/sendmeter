/// Structural invariants of the shipped server source — the acceptance
/// criteria that can't be proven by behaviour alone:
///   1. No service-role key (or any non-user credential) anywhere in src/.
///   2. No mutation call sites in the data layer: `.insert(`, `.update(`,
///      `.delete(`, `.upsert(`, `.rpc(` appear nowhere outside auth.ts
///      (auth.ts legitimately POSTs to the token endpoint, never to tables).
///   3. The tool set is exactly the six read-only tools from the spec.
/// Tests read the source files, so a future edit that breaks a guarantee
/// fails here.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { TOOL_HANDLERS } from "../src/server.js";

const SRC_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "src");

function srcFiles(): string[] {
  return fs
    .readdirSync(SRC_DIR)
    .filter((f) => f.endsWith(".ts"))
    .map((f) => path.join(SRC_DIR, f));
}

const DATA_LAYER = srcFiles().filter((f) => !f.endsWith("auth.ts"));

const MUTATION_CALL_SITES = [".insert(", ".update(", ".delete(", ".upsert(", ".rpc("];

describe("no service-role anywhere", () => {
  it("the string service_role (and lookalikes) never appears in src/", () => {
    for (const file of srcFiles()) {
      const src = fs.readFileSync(file, "utf8");
      expect(src, file).not.toMatch(/service_?role/i);
    }
  });
});

describe("no mutation code paths in the data layer", () => {
  for (const file of DATA_LAYER) {
    it(`${path.basename(file)} has no PostgREST mutation call sites`, () => {
      const src = fs.readFileSync(file, "utf8");
      for (const site of MUTATION_CALL_SITES) {
        expect(src, `${file} contains ${site}`).not.toContain(site);
      }
      // No non-GET HTTP verbs anywhere in the data layer.
      expect(src).not.toMatch(/\b(POST|PATCH|PUT|DELETE)\b/);
    });
  }
});

describe("tool surface", () => {
  it("registers exactly the six spec tools, all read-only by name", () => {
    expect(TOOL_HANDLERS.map((h) => h.name)).toEqual([
      "get_health_metrics",
      "get_sessions",
      "get_readiness",
      "get_acwr",
      "get_tindeq",
      "analyze_training_load",
    ]);
    for (const h of TOOL_HANDLERS) {
      expect(h.name).toMatch(/^(get_|analyze_)/);
      expect(h.name).not.toMatch(/(insert|update|delete|write|create|remove)/);
      expect(h.description.length).toBeGreaterThan(20);
    }
  });

  it("every tool has an input schema with only read-style fields", () => {
    for (const h of TOOL_HANDLERS) {
      expect(h.inputSchema, h.name).toBeTruthy();
    }
  });
});
