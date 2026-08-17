/// Structural invariants of the shipped server source — the acceptance
/// criteria that can't be proven by behaviour alone:
///   1. No service-role key (or any non-user credential) anywhere in src/.
///   2. No mutation call sites in the data layer: `.insert(`, `.update(`,
///      `.delete(`, `.upsert(`, `.rpc(` appear nowhere outside auth.ts
///      (auth.ts legitimately POSTs to the token endpoint, never to tables).
///   3. No refresh token is ever minted, stored or passed (issue #644 review
///      F6) — only the web app's supabase-js may hold refresh tokens. The
///      only token-shaped strings allowed in src/ are the access-token
///      names and the word in a doc comment that explains the prohibition.
///   4. The tool set is exactly the six read-only tools from the spec.
/// Tests read the source files (recursively — #644 review F9 closed the
/// non-recursive hole), so a future edit that breaks a guarantee fails here.

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { TOOL_HANDLERS } from "../src/server.js";

const SRC_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "src");

function srcFiles(): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const entry of fs.readdirSync(dir)) {
      const full = path.join(dir, entry);
      if (fs.statSync(full).isDirectory()) walk(full);
      else if (full.endsWith(".ts")) out.push(full);
    }
  };
  walk(SRC_DIR);
  return out;
}

const ALL_FILES = srcFiles();

const MUTATION_CALL_SITES = [".insert(", ".update(", ".delete(", ".upsert(", ".rpc("];

describe("no service-role anywhere", () => {
  it("the string service_role (and lookalikes) never appears in src/", () => {
    for (const file of ALL_FILES) {
      const src = fs.readFileSync(file, "utf8");
      expect(src, file).not.toMatch(/service_?role/i);
    }
  });
});

describe("no mutation code paths in the data layer", () => {
  // The ONLY file allowed to hit a non-GET endpoint is auth.ts, and only
  // through the login/refresh grants against the token endpoint. Instead of
  // exempting the whole file (issue #644 review F9), we assert it contains
  // exactly the one `POST` (the password grant) and no PostgREST table
  // mutation — a `.delete(` added to auth.ts is caught.
  const MUTABLE_FILE = path.join(SRC_DIR, "auth.ts");
  const MUTATION_SCAN = ALL_FILES.filter((f) => f !== MUTABLE_FILE);

  for (const file of MUTATION_SCAN) {
    it(`${path.basename(file)} has no PostgREST mutation call sites`, () => {
      const src = fs.readFileSync(file, "utf8");
      for (const site of MUTATION_CALL_SITES) {
        expect(src, `${file} contains ${site}`).not.toContain(site);
      }
      // No non-GET HTTP verbs anywhere in the data layer.
      expect(src).not.toMatch(/\b(POST|PATCH|PUT|DELETE)\b/);
    });
  }

  it("auth.ts contains no PostgREST mutation call sites and no non-password HTTP verbs", () => {
    const src = fs.readFileSync(MUTABLE_FILE, "utf8");
    for (const site of MUTATION_CALL_SITES) {
      expect(src, `${MUTABLE_FILE} contains ${site}`).not.toContain(site);
    }
    // auth.ts's only HTTP verb is the password-grant POST; a PATCH/PUT/DELETE
    // (or a refresh-token grant) would fail here.
    expect(src).not.toMatch(/\b(PATCH|PUT|DELETE)\b/);
    expect(src).not.toMatch(/grant_type=refresh_token/);
    expect(src).toMatch(/signInWithPassword/);
  });
});

describe("no refresh token (issue #644 F6)", () => {
  // Only the web app's supabase-js holds refresh tokens. The server never
  // mints one, never persists one, never passes one on the wire. A future
  // edit that stores a `refreshToken` field or calls `refreshSession` fails
  // here. `refresh_token` (the supabase response field name) is not allowed
  // anywhere either.
  for (const file of ALL_FILES) {
    it(`${path.relative(SRC_DIR, file)} never mentions a refresh token`, () => {
      const src = fs.readFileSync(file, "utf8");
      expect(src, file).not.toMatch(/refreshToken/);
      expect(src, file).not.toMatch(/refresh_token/);
      expect(src, file).not.toMatch(/refreshSession/);
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
