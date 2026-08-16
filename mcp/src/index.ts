#!/usr/bin/env node
/// sendmeter-mcp entry point.
///
/// Default mode: resolve the user's Supabase session, build the read-only
/// store, and serve the six tools over stdio (JSON-RPC) for any MCP client.
///   SENDMETER_MCP_TOKEN        — ready-made access token (never persisted)
///   SENDMETER_MCP_EMAIL/PASSWORD — non-interactive PKCE sign-in
///   SENDMETER_MCP_URL/ANON_KEY — override the Supabase project (local stack)
///   SENDMETER_MCP_SESSION_FILE — override the 0600 session-file location
///
/// --dry-run: exercise every tool against an in-memory stub store — no
/// network, no credentials. Proves wiring on machines without the stack.

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadConfig } from "./config.js";
import { createAuthClient, promptHidden, resolveSession } from "./auth.js";
import { createSupabaseStore } from "./transport.js";
import { buildServer, TOOL_HANDLERS } from "./server.js";
import { dryRunStore } from "./dryrun.js";
import { daysAgo, today } from "./dates.js";

const HELP = `sendmeter-mcp — local read-only MCP server for Sendmeter data.

Usage:
  sendmeter-mcp            serve tools over stdio (the MCP default)
  sendmeter-mcp --dry-run  exercise all 6 tools against synthetic data
                           (no network, no credentials)
  sendmeter-mcp --help     this text

Session credentials (first run):
  SENDMETER_MCP_TOKEN       an access token from your Sendmeter session
  SENDMETER_MCP_EMAIL/PASSWORD  sign in non-interactively (PKCE)
  or run interactively and enter them at the prompt.

See mcp/README.md for full setup.
`;

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(HELP);
    return;
  }

  // Dry-run needs no session: it exercises every tool against synthetic
  // data, so it must work with zero credentials and zero network.
  if (argv.includes("--dry-run")) {
    process.stdout.write(
      `sendmeter-mcp dry-run: exercising ${TOOL_HANDLERS.length} tools against synthetic data ` +
        "(no network, no credentials)\n\n",
    );
    await runDryRunAsync(dryRunStore(), EXAMPLES);
    return;
  }

  const config = loadConfig();

  // Kick the session resolution off immediately but don't await it before
  // connecting the transport — the client's initialize must be answered the
  // moment it arrives, even while the PKCE login is still in flight. Tool
  // calls block on this promise only when they need the store.
  const sessionPromise = resolveSession({
    config,
    auth: createAuthClient(config.supabaseUrl, config.supabaseAnonKey),
    prompt: async (q, hidden) => {
      try {
        return await promptHidden(q, hidden);
      } catch {
        throw new Error(
          "interactive sign-in unavailable in this shell — set SENDMETER_MCP_EMAIL/SENDMETER_MCP_PASSWORD",
        );
      }
    },
  });
  let storePromise: Promise<ReturnType<typeof createSupabaseStore>> | null = null;
  const getStore = () => {
    storePromise ??= sessionPromise.then((session) =>
      createSupabaseStore({
        url: config.supabaseUrl,
        anonKey: config.supabaseAnonKey,
        accessToken: session.accessToken,
      }),
    );
    return storePromise;
  };

  const server = buildServer(getStore);
  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Banner (stderr — stdout is JSON-RPC) once the session is known; a
  // resolution failure exits loudly rather than serving broken tool calls.
  const session = await sessionPromise;
  process.stderr.write(
    `sendmeter-mcp: serving ${TOOL_HANDLERS.length} read-only tools for ` +
      `${session.email ?? "token-authenticated user"} @ ${config.supabaseUrl}\n`,
  );
}

const EXAMPLES: Record<string, Record<string, unknown>> = {
  get_health_metrics: { from: daysAgo(6), to: today(), metric: "hrv" },
  get_sessions: { from: daysAgo(30), to: today() },
  get_readiness: { days: 14 },
  get_acwr: { days: 90 },
  get_tindeq: { session_id: "aaaaaaaa-0000-0000-0000-000000000002" },
  analyze_training_load: { weeks: 4, days: 90 },
};

async function runDryRunAsync(
  store: ReturnType<typeof dryRunStore>,
  examples: Record<string, Record<string, unknown>>,
): Promise<void> {
  for (const h of TOOL_HANDLERS) {
    const args = examples[h.name] ?? {};
    try {
      const parsed = h.inputSchema.parse(args);
      const result = await h.run(parsed, store);
      process.stdout.write(`── ${h.name} ${JSON.stringify(args)}\n`);
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n\n`);
    } catch (err) {
      process.stdout.write(
        `── ${h.name}: FAILED: ${err instanceof Error ? err.message : String(err)}\n\n`,
      );
      process.exitCode = 1;
    }
  }
}

main().catch((err) => {
  process.stderr.write(
    `sendmeter-mcp: ${err instanceof Error ? err.message : String(err)}\n`,
  );
  process.exit(1);
});
