/// Full JSON-RPC round trip through the real MCP server: register the six
/// tools against a mock store, connect client ↔ server over the SDK's
/// in-memory transport, and call tools by name exactly like a client would.
/// Also pins the CallToolResult shape (text content, structured errors).

import { describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { buildServer, SERVER_NAME, SERVER_VERSION } from "../src/server.js";
import type { DataStore } from "../src/transport.js";
import { dryRunStore } from "../src/dryrun.js";
import { day } from "./helpers.js";

/// Wraps an InMemoryTransport so every message the server sends can be
/// inspected — used to read the serverInfo the server advertises on the
/// wire (the high-level Client does not expose it after connect).
class RecordingTransport extends InMemoryTransport {
  messages: Record<string, unknown>[] = [];
  constructor(private readonly inner: InMemoryTransport) {
    super();
    this.start = () => {
      this.inner.onmessage = (msg) => this.onmessage?.(msg);
      this.onclose = () => this.inner.onclose?.();
      return Promise.resolve();
    };
    this.close = () => this.inner.close();
  }
  override async send(message: Record<string, unknown>): Promise<void> {
    this.messages.push(JSON.parse(JSON.stringify(message)));
    return this.inner.send(message);
  }
}

async function withClient(
  store: DataStore,
  fn: (client: Client) => Promise<void>,
): Promise<void> {
  const server = buildServer(async () => store);
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "test-client", version: "1.0.0" });
  // Server first: the in-memory pair queues the client's initialize until the
  // server side starts, so connecting the client first deadlocks.
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  try {
    await fn(client);
  } finally {
    await client.close();
    await server.close();
  }
}

describe("sendmeter-mcp server", () => {
  it("advertises the six tools over JSON-RPC", async () => {
    await withClient(dryRunStore(), async (client) => {
      const { tools } = await client.listTools();
      expect(tools.map((t) => t.name).sort()).toEqual(
        ["analyze_training_load", "get_acwr", "get_health_metrics", "get_readiness", "get_sessions", "get_tindeq"],
      );
      for (const t of tools) {
        expect(t.inputSchema).toBeTruthy();
      }
    });
  });

  it("answers 'summarise this week's training' with data-grounded output", async () => {
    await withClient(dryRunStore(), async (client) => {
      const result = await client.callTool({
        name: "analyze_training_load",
        arguments: { weeks: 4, days: 90 },
      });
      expect(result.isError).toBeFalsy();
      const text = result.content[0]!.text;
      expect(text).toContain('"load_trend"');
      expect(text).toContain('"acwr"');
      expect(text).toContain('"recovery"');
      const parsed = JSON.parse(text) as {
        weekly_load: { total_load: number }[];
        load_trend: string;
      };
      expect(parsed.weekly_load).toHaveLength(4);
      expect(typeof parsed.load_trend).toBe("string");
    });
  });

  it("applies schema defaults and rejects bad arguments with a structured error", async () => {
    await withClient(dryRunStore(), async (client) => {
      const withDefaults = await client.callTool({
        name: "get_readiness",
        arguments: {},
      });
      expect(withDefaults.isError).toBeFalsy();
      const parsed = JSON.parse(withDefaults.content[0]!.text) as { days: number };
      expect(parsed.days).toBe(14);

      const bad = await client.callTool({
        name: "get_health_metrics",
        arguments: { from: "not-a-date", to: "2026-07-07" },
      });
      expect(bad.isError).toBe(true);
      expect(bad.content[0]!.text).toContain("error");

      const inverted = await client.callTool({
        name: "get_health_metrics",
        arguments: { from: "2026-08-01", to: "2026-07-01" },
      });
      expect(inverted.isError).toBe(true);
    });
  });

  it("surfaces store failures as isError results, not crashes", async () => {
    const failing: DataStore = {
      async healthMetrics() {
        throw new Error("permission denied for table health_metrics");
      },
    } as DataStore;
    await withClient(failing, async (client) => {
      const result = await client.callTool({
        name: "get_health_metrics",
        arguments: { from: day(1), to: day(0) },
      });
      expect(result.isError).toBe(true);
      expect(result.content[0]!.text).toContain("permission denied");
    });
  });

  it("answers initialize and listTools while a slow store is still resolving", async () => {
    const server = buildServer(async () => {
      await new Promise((r) => setTimeout(r, 300));
      return dryRunStore();
    });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    const client = new Client({ name: "lazy-store-probe", version: "1.0.0" });
    await client.connect(clientTransport);
    const started = Date.now();
    const { tools } = await client.listTools();
    const elapsed = Date.now() - started;
    expect(tools).toHaveLength(6);
    // The store takes 300ms to resolve; the handshake must not wait for it.
    expect(elapsed).toBeLessThan(250);
    // A tool call DOES wait for the store.
    const result = await client.callTool({ name: "get_readiness", arguments: { days: 7 } });
    expect(result.isError).toBeFalsy();
    await client.close();
    await server.close();
  });

  it("identifies as sendmeter-mcp on the wire (initialize serverInfo)", async () => {
    const server = buildServer(async () => dryRunStore());
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const recorder = new RecordingTransport(serverTransport);
    await server.connect(recorder);
    const client = new Client({ name: "identity-probe", version: "1.0.0" });
    await client.connect(clientTransport);
    const info = recorder.messages
      .map((m) => m.result as { serverInfo?: { name?: string; version?: string } })
      .find((r) => r?.serverInfo);
    expect(info?.serverInfo?.name).toBe(SERVER_NAME);
    expect(info?.serverInfo?.version).toBe(SERVER_VERSION);
    await client.close();
    await server.close();
  });
});
