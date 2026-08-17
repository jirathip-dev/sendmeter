/// Manual end-to-end harness for sendmeter-mcp: spawns the real server over
/// stdio (an MCP client doing a full initialize → listTools → callTool
/// session) and exercises all six tools. NOT part of the unit suite — it
/// needs a live Supabase project.
///
/// Usage (local stack):
///   npm run build
///   MCP_URL=http://127.0.0.1:54321 MCP_ANON=<local anon key> \
///     MCP_EMAIL=dev@sendmeter.test MCP_PASSWORD=devpassword \
///     node scripts/e2e.mjs
///
/// Hosted: MCP_URL/MCP_ANON default to the hosted project in the server, so
/// only a credential (MCP_TOKEN, or MCP_EMAIL/MCP_PASSWORD) is required.
/// TINDEQ_ID overrides the recording id used by the get_tindeq probe.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const label = process.env.LABEL ?? "user";
const env = {
  PATH: process.env.PATH,
  SENDMETER_MCP_URL: process.env.MCP_URL,
  SENDMETER_MCP_ANON_KEY: process.env.MCP_ANON,
};
for (const [src, dst] of [
  ["MCP_TOKEN", "SENDMETER_MCP_TOKEN"],
  ["MCP_EMAIL", "SENDMETER_MCP_EMAIL"],
  ["MCP_PASSWORD", "SENDMETER_MCP_PASSWORD"],
]) {
  const v = process.env[src];
  if (v !== undefined && v !== "") env[dst] = v;
}

const transport = new StdioClientTransport({
  command: "node",
  args: ["dist/index.js"],
  env,
  stderr: "pipe",
});
const client = new Client({ name: "e2e", version: "1.0.0" });
let stderr = "";
transport.stderr?.on("data", (d) => { stderr += d.toString(); });
await client.connect(transport);

const tools = (await client.listTools()).tools;
console.log(`[${label}] tools served: ${tools.map(t => t.name).join(", ")}`);

const calls = [
  ["get_health_metrics", { from: "2026-08-01", to: "2026-08-16", metric: "hrv" }],
  ["get_sessions", { from: "2026-07-01", to: "2026-08-16" }],
  ["get_readiness", { days: 14 }],
  ["get_acwr", { days: 90 }],
  ["get_tindeq", { recording_id: process.env.TINDEQ_ID ?? "2b8ec906-950c-4eb8-aa4b-3f20b0337f5d" }],
  ["analyze_training_load", { weeks: 4, days: 90 }],
];
for (const [name, args] of calls) {
  const r = await client.callTool({ name, arguments: args });
  const text = r.content[0].text;
  let summary;
  try {
    summary = await summarize(name, JSON.parse(text));
  } catch {
    summary = text;
  }
  console.log(`[${label}] ${name} -> ${r.isError ? "ERROR" : "ok"} ${summary}`);
}

async function summarize(name, v) {
  switch (name) {
    case "get_health_metrics": return `days=${v.days} rows=${v.series.length} sample=${JSON.stringify(v.series[0] ?? null)}`;
    case "get_sessions": return `sessions=${v.session_count} load=${v.total_load} days=${v.days.length}`;
    case "get_readiness": return `latest=${JSON.stringify(v.latest)} avg=${v.summary.avg_readiness}`;
    case "get_acwr": return `acwr=${v.acwr} (${v.status}) phase=${v.phase}`;
    case "get_tindeq": return `recordings=${v.recordings.length} best=${v.summary.best_peak_kg} peaks=${v.peaks.length}`;
    case "analyze_training_load": return `trend=${v.load_trend} acwr=${v.acwr.acwr} notes=${v.notes.length}`;
  }
}

await client.close();
console.log(`[${label}] server stderr: ${stderr.trim()}`);
