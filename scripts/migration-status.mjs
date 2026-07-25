#!/usr/bin/env node
// Compares supabase/migrations/ against the schema_migrations ledgers of BOTH
// Supabase projects (dev and prod) and prints a parity table.
//
// Comparison is by NAME, never by version: dev records the *file* timestamp
// while prod's MCP apply_migration era recorded an *apply-time* one, so the
// same migration legitimately has different versions on the two projects. A
// version-based diff reports false drift. (Ported from synergy-costing, which
// hit this first.)
//
// The ledger only records what was REPORTED applied — it is not proof the
// objects exist. A green table means "nothing pending", not "schemas match".
//
// AUTH — ONE token reaches both projects. The projects are on two different
// Supabase accounts and the main account is only a Developer on the dev one,
// but Developer is sufficient for the Management API: verified 2026-07-25 that
// the main-account token can POST /database/query against the dev project.
//   SUPABASE_ACCESS_TOKEN, else ~/.supabase/access-token
// The per-project overrides below exist only as an escape hatch if the accounts
// ever diverge; you should not need them.
//
// Usage: node scripts/migration-status.mjs
// Exits 1 if any local migration is unrecorded on either project.

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const PROJECTS = {
  dev: "mjkndfhjnipomjjhgsxv",
  prod: "zznsqmcewtzlnfoiefkk",
};

const MIGRATIONS_DIR = join(
  dirname(dirname(fileURLToPath(import.meta.url))),
  "supabase",
  "migrations",
);
const FILENAME_RE = /^(\d{14})_([a-z0-9_]+)\.sql$/;

function fromFile(path) {
  return existsSync(path) ? readFileSync(path, "utf8").trim() : null;
}

function tokenFor(which) {
  if (which === "prod") {
    return (
      process.env.SUPABASE_ACCESS_TOKEN_PROD?.trim() ||
      process.env.SUPABASE_ACCESS_TOKEN?.trim() ||
      fromFile(join(homedir(), ".supabase", "access-token"))
    );
  }
  return (
    process.env.SUPABASE_ACCESS_TOKEN_DEV?.trim() ||
    process.env.SUPABASE_ACCESS_TOKEN?.trim() ||
    fromFile(join(homedir(), ".supabase", "access-token")) ||
    fromFile(join(homedir(), ".supabase", "dev-account-token"))
  );
}

async function ledger(which, ref) {
  const token = tokenFor(which);
  if (!token) {
    console.error(
      `✗ No Management API token for ${which}. See the AUTH note at the top of this file.`,
    );
    process.exit(2);
  }
  const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      query: "select version, name from supabase_migrations.schema_migrations order by version",
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    console.error(`✗ Ledger query failed for ${which} (${ref}): HTTP ${res.status} ${body}`);
    if (res.status === 401 || res.status === 403) {
      console.error(
        "  401 'JWT could not be decoded' means the token itself is expired or revoked,\n" +
          "  not that it lacks rights. Generate a fresh one at Dashboard > Account >\n" +
          "  Access Tokens; one token works for both projects.",
      );
    }
    process.exit(2);
  }
  const body = await res.json();
  const rows = Array.isArray(body) ? body : (body.result ?? body.rows ?? []);
  // name → [versions]; a name can appear twice if ever double-recorded
  const byName = new Map();
  for (const r of rows) {
    if (!byName.has(r.name)) byName.set(r.name, []);
    byName.get(r.name).push(r.version);
  }
  return byName;
}

const [dev, prod] = await Promise.all([
  ledger("dev", PROJECTS.dev),
  ledger("prod", PROJECTS.prod),
]);

const local = readdirSync(MIGRATIONS_DIR)
  .filter((f) => f.endsWith(".sql"))
  .sort()
  .map((f) => {
    const m = FILENAME_RE.exec(f);
    if (!m) console.warn(`! skipping unparseable filename: ${f}`);
    return m ? { version: m[1], name: m[2], file: f } : null;
  })
  .filter(Boolean);

const nameW = Math.max(...local.map((m) => m.name.length), 4);
console.log(`${"name".padEnd(nameW)}  ${"local".padEnd(14)}  dev             prod`);
console.log("-".repeat(nameW + 50));

let missing = 0;
for (const m of local) {
  const d = dev.get(m.name);
  const p = prod.get(m.name);
  if (!d || !p) missing++;
  const cell = (v) => (v ? `✓ ${v[0]}` : "✗ MISSING").padEnd(16);
  console.log(`${m.name.padEnd(nameW)}  ${m.version}  ${cell(d)}${cell(p)}`);
}

const localNames = new Set(local.map((m) => m.name));
for (const [label, l] of [
  ["dev", dev],
  ["prod", prod],
]) {
  const foreign = [...l.keys()].filter((n) => !localNames.has(n));
  if (foreign.length) {
    console.log(`\n${label}-only ledger entries with no local file: ${foreign.length}`);
    for (const n of foreign) console.log(`  ${n}`);
  }
}

if (missing) {
  console.error(
    `\n✗ ${missing} local migration(s) unrecorded on dev or prod — pending apply, or\n` +
      `  applied without a ledger insert. Resolve before enabling automated migrations (#130).`,
  );
  process.exit(1);
}

console.log("\n✓ every local migration is recorded on both projects.");
