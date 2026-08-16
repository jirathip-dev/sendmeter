/// MCP server assembly: registers the six read-only tools with the official
/// SDK, validates args through the shared zod schemas (the SDK parses
/// incoming arguments against `inputSchema`), and shapes every result as a
/// JSON-RPC CallToolResult. The store is injected so tests can register the
/// tools against a mock without network.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { DataStore } from "./transport.js";
import {
  analyzeTrainingLoad,
  getAcwr,
  getHealthMetrics,
  getReadiness,
  getSessions,
  getTindeq,
} from "./queries.js";
import {
  analyzeTrainingLoadSchema,
  getAcwrSchema,
  getHealthMetricsSchema,
  getReadinessSchema,
  getSessionsSchema,
  getTindeqSchema,
} from "./tools.js";

export const SERVER_NAME = "sendmeter-mcp";
export const SERVER_VERSION = "0.1.0";

export interface ToolHandler {
  name: string;
  description: string;
  inputSchema: z.ZodType;
  run: (args: unknown, store: DataStore) => Promise<unknown>;
}

function tool<P extends z.ZodType, R>(
  name: string,
  description: string,
  inputSchema: P,
  run: (args: z.infer<P>, store: DataStore) => Promise<R>,
): ToolHandler {
  return { name, description, inputSchema, run: run as ToolHandler["run"] };
}

export const TOOL_HANDLERS: ToolHandler[] = [
  tool(
    "get_health_metrics",
    "Daily health metrics (HRV, resting HR, sleep, body weight) over a date range. " +
      "Returns one object per day with the requested metric columns.",
    getHealthMetricsSchema,
    getHealthMetrics,
  ),
  tool(
    "get_sessions",
    "Training sessions over a date range: per-day aggregates (duration, load, RPE, " +
      "session types) plus a flat total and watch/phone workout attempt counts.",
    getSessionsSchema,
    getSessions,
  ),
  tool(
    "get_readiness",
    "Daily readiness scores (0-100) for the trailing N days, with average/min/max and " +
      "a count of days below the recovery threshold.",
    getReadinessSchema,
    getReadiness,
  ),
  tool(
    "get_acwr",
    "Acute:chronic workload ratio as of today — 7-day acute load, 28-day chronic average, " +
      "the EWMA-derived ratio and its risk-zone label, plus the current training phase.",
    getAcwrSchema,
    getAcwr,
  ),
  tool(
    "get_tindeq",
    "Finger-strength (Tindeq) recordings: a single recording, a gauge session (group_id), " +
      "or the most recent ones. Returns per-recording summaries (peak/avg kg, duration) and " +
      "top force peaks derived from the sample curves when samples are in scope.",
    getTindeqSchema,
    getTindeq,
  ),
  tool(
    "analyze_training_load",
    "Training-load trend over the trailing N weeks (weekly load, session count, avg RPE), " +
      "the ACWR ratio, readiness trend, low-readiness days, and a list of data-grounded " +
      "signal notes (recovery deficit, over/under-training).",
    analyzeTrainingLoadSchema,
    analyzeTrainingLoad,
  ),
];

/// Build the MCP server with the six read-only tools. The store is provided
/// lazily (via a provider) so the transport can be connected and answer the
/// client's initialize IMMEDIATELY, before any slow session work (network
/// sign-in) has finished — an initialize that arrives during a ~100ms login
/// is otherwise dropped on the floor and the client sees a dead server.
/// The SDK validates the incoming arguments against each tool's schema
/// (defaults applied); every handler failure becomes a structured `isError`
/// result, never a thrown request error.
export function buildServer(getStore: () => Promise<DataStore>): McpServer {
  const server = new McpServer(
    { name: SERVER_NAME, version: SERVER_VERSION },
    { capabilities: { tools: {} } },
  );
  for (const h of TOOL_HANDLERS) {
    server.registerTool(
      h.name,
      { title: h.name, description: h.description, inputSchema: h.inputSchema },
      async (args) => {
        try {
          const store = await getStore();
          const result = await h.run(args, store);
          return {
            content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
          };
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          return {
            content: [{ type: "text", text: `error: ${message}` }],
            isError: true,
          };
        }
      },
    );
  }
  return server;
}
