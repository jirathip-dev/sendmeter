#!/usr/bin/env node
// Applies pending migrations to ONE project (dev or prod) via the Management
// API — the CD engine behind .github/workflows/deploy-migrations.yml (#130).
//
// Comparison is by NAME, never by version, same as migration-status.mjs: prod's
// ledger carries apply-time versions from the MCP `apply_migration` era, so
// `supabase db push` (which diffs by version) would re-apply recorded history.
// This script:
//
//   1. fetches the target's schema_migrations ledger,
//   2. pending = local files whose *name* is not recorded,
//   3. refuses to run unless pending is purely appends — every pending file
//      must be NEWER than the newest recorded one. An older unrecorded file is
//      history applied without its ledger row: backfill the ledger row by hand,
//      NEVER re-run the SQL,
//   4. applies each pending file in order, records it with the FILE version
//      (plain insert — a conflict fails loudly, no `on conflict do nothing`),
//      then re-verifies the ledger.
//
// The Management API path needs no DB password and no `supabase link`, so
// supabase/config.toml's hardcoded prod ref cannot misfire — the ref is chosen
// here by --target.
//
// Dependency-free (node 18+ fetch). Auth: SUPABASE_ACCESS_TOKEN, else
// ~/.supabase/access-token. ONE token reaches both projects even though they
// live on different Supabase accounts — Developer role is sufficient for the
// Management API (see CLAUDE.md).
//
// Usage: node scripts/apply-migrations.mjs --target dev|prod

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const PROJECTS = {
  dev: "mjkndfhjnipomjjhgsxv",
  prod: "zznsqmcewtzlnfoiefkk",
};

const targetArg = process.argv.indexOf("--target");
const target = targetArg === -1 ? null : process.argv[targetArg + 1];
if (!target || !(target in PROJECTS)) {
  console.error("Usage: apply-migrations.mjs --target dev|prod");
  process.exit(2);
}
const ref = PROJECTS[target];

const MIGRATIONS_DIR = join(
  dirname(dirname(fileURLToPath(import.meta.url))),
  "supabase",
  "migrations",
);
const FILENAME_RE = /^(\d{14})_([a-z0-9_]+)\.sql$/;

function accessToken() {
  if (process.env.SUPABASE_ACCESS_TOKEN) return process.env.SUPABASE_ACCESS_TOKEN.trim();
  const tokenFile = join(homedir(), ".supabase", "access-token");
  if (existsSync(tokenFile)) return readFileSync(tokenFile, "utf8").trim();
  console.error("✗ No Management API token found. Set SUPABASE_ACCESS_TOKEN.");
  process.exit(2);
}

async function query(token, sql, label) {
  const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query: sql }),
  });
  if (!res.ok) {
    const body = await res.text();
    console.error(`✗ ${label} failed on ${target}: HTTP ${res.status} ${body}`);
    if (res.status === 401 || res.status === 403) {
      console.error(
        "  401 'JWT could not be decoded' means the token is expired or revoked,\n" +
          "  not that it lacks rights. One token works for both projects.",
      );
    }
    process.exit(1);
  }
  const body = await res.json();
  return Array.isArray(body) ? body : (body.result ?? body.rows ?? []);
}

async function recordedNames(token) {
  const rows = await query(
    token,
    "select name from supabase_migrations.schema_migrations",
    "ledger query",
  );
  return new Set(rows.map((r) => r.name));
}

const token = accessToken();
const local = readdirSync(MIGRATIONS_DIR)
  .filter((f) => f.endsWith(".sql"))
  .sort()
  .map((f) => {
    const m = FILENAME_RE.exec(f);
    if (!m) {
      console.error(`✗ ${f} doesn't match YYYYMMDDHHMMSS_name.sql`);
      process.exit(1);
    }
    return { version: m[1], name: m[2], file: f };
  });

const recorded = await recordedNames(token);
const pending = local.filter((m) => !recorded.has(m.name));

if (pending.length === 0) {
  console.log(`✓ ${target} is up to date — all ${local.length} migrations recorded`);
  process.exit(0);
}

// Append-only guard: pending must all be newer than the newest recorded file.
const applied = local.filter((m) => recorded.has(m.name));
const newestApplied = applied.length ? applied[applied.length - 1].version : "0";
const historical = pending.filter((m) => m.version <= newestApplied);
if (historical.length) {
  console.error(
    `✗ ${historical.length} unrecorded migration(s) on ${target} are OLDER than the newest ` +
      `recorded one (${newestApplied}) — this is history applied without a ledger row, not new work.\n` +
      `  NEVER re-run these. Backfill the ledger row instead, then re-run:`,
  );
  for (const m of historical) console.error(`    ${m.file}`);
  process.exit(1);
}

console.log(`${pending.length} pending migration(s) for ${target} (${ref}):`);
for (const m of pending) console.log(`  ${m.file}`);

for (const m of pending) {
  const sql = readFileSync(join(MIGRATIONS_DIR, m.file), "utf8");
  await query(token, sql, `apply ${m.file}`);
  // FILENAME_RE guarantees version/name are [0-9] / [a-z0-9_] — safe to inline.
  await query(
    token,
    `insert into supabase_migrations.schema_migrations (version, name) values ('${m.version}', '${m.name}')`,
    `ledger insert for ${m.file}`,
  );
  console.log(`✓ applied + recorded ${m.file}`);
}

const after = await recordedNames(token);
const stillMissing = local.filter((m) => !after.has(m.name));
if (stillMissing.length) {
  console.error(`✗ post-apply verification failed — still unrecorded on ${target}:`);
  for (const m of stillMissing) console.error(`  ${m.file}`);
  process.exit(1);
}
console.log(`✓ ${target} ledger verified — all ${local.length} migrations recorded`);
