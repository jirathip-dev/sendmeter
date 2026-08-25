import { beforeEach, describe, expect, it, vi } from "vitest";
import { today } from "../dates";

type FakeResult = {
  data: unknown;
  error: { message: string; code?: string } | null;
};

type Operation = {
  method: string;
  args: unknown[];
};

type Call = {
  table: string;
  operations: Operation[];
};

const h = vi.hoisted(() => ({
  calls: [] as Call[],
  selectResults: [] as FakeResult[],
  rpcCalls: [] as { name: string; args: unknown }[],
  authUser: { id: "user-1" },
}));

function chainable(table: string) {
  const call: Call = { table, operations: [] };
  h.calls.push(call);
  let result: FakeResult = { data: [], error: null };
  let mutation = false;
  const chain = {} as {
    [key: string]: unknown;
    then: (
      resolve: (value: FakeResult) => unknown,
      reject?: (reason: unknown) => unknown,
    ) => Promise<unknown>;
  };
  const record = (method: string, ...args: unknown[]) => {
    call.operations.push({ method, args });
    return chain;
  };

  for (const method of [
    "eq",
    "is",
    "not",
    "in",
    "gte",
    "lt",
    "order",
    "limit",
    "maybeSingle",
    "single",
    "overrideTypes",
  ]) {
    chain[method] = (...args: unknown[]) => record(method, ...args);
  }
  for (const method of ["update", "insert", "upsert", "delete"]) {
    chain[method] = (...args: unknown[]) => {
      mutation = true;
      return record(method, ...args);
    };
  }
  chain.select = (...args: unknown[]) => {
    record("select", ...args);
    if (mutation) {
      result = { data: { id: "mutated-row" }, error: null };
    } else {
      result = h.selectResults.shift() ?? { data: [], error: null };
    }
    return chain;
  };
  chain.then = (
    resolve: (value: FakeResult) => unknown,
    reject?: (reason: unknown) => unknown,
  ) => Promise.resolve(result).then(resolve, reject);
  return chain;
}

vi.mock("../supabase", () => ({
  supabase: {
    from: (table: string) => chainable(table),
    rpc: (name: string, args: unknown) => {
      h.rpcCalls.push({ name, args });
      return Promise.resolve({ data: true, error: null });
    },
    auth: {
      getUser: () =>
        Promise.resolve({ data: { user: h.authUser }, error: null }),
    },
  },
}));

const {
  deleteRecording,
  deletePreset,
  fetchPresets,
  fetchRecordings,
  purgeRecording,
} = await import("./tindeq");
const { purgeSession } = await import("./sessions");
const { fetchPhasePeriods, switchPhase } = await import("./phases");
const { fetchRoutinePresets, deleteRoutinePreset } = await import("./workouts");

function hasNullDeletedAtFilter(call: Call): boolean {
  return call.operations.some(
    ({ method, args }) =>
      method === "is" && args[0] === "deleted_at" && args[1] === null,
  );
}

function updatesFor(table: string): unknown[] {
  return h.calls
    .filter((call) => call.table === table)
    .flatMap((call) =>
      call.operations
        .filter(({ method }) => method === "update")
        .map(({ args }) => args[0]),
    );
}

describe("Trash repository convergence (#778)", () => {
  beforeEach(() => {
    h.calls.length = 0;
    h.selectResults.length = 0;
    h.rpcCalls.length = 0;
  });

  it("filters active phase, recording, preset, and routine rows by deleted_at IS NULL", async () => {
    await fetchPhasePeriods();
    await fetchRecordings();
    await fetchPresets();
    await fetchRoutinePresets();

    for (const table of [
      "phase_periods",
      "tindeq_recordings",
      "tindeq_presets",
      "routine_presets",
    ]) {
      const call = h.calls.find((candidate) => candidate.table === table);
      expect(call, `${table} query was not issued`).toBeDefined();
      expect(hasNullDeletedAtFilter(call!)).toBe(true);
    }
  });

  it("converts phase undo and Trash deletes into soft-delete updates", async () => {
    const open = {
      id: "open",
      phase: "capacity",
      started_on: today(),
      ended_on: null,
    };
    const previous = {
      id: "previous",
      phase: "strength",
      started_on: "2026-08-01",
      ended_on: today(),
    };
    h.selectResults.push(
      { data: [open, previous], error: null },
      { data: [previous], error: null },
    );

    await switchPhase("strength");
    await deletePreset("preset-1");
    await deleteRecording("recording-1");
    await deleteRoutinePreset("routine-1");

    const phaseUpdates = updatesFor("phase_periods");
    expect(phaseUpdates).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ deleted_at: expect.any(String) }),
        { ended_on: null },
      ]),
    );
    expect(updatesFor("tindeq_presets")).toEqual([
      expect.objectContaining({ deleted_at: expect.any(String) }),
    ]);
    expect(updatesFor("tindeq_recordings")).toEqual([
      expect.objectContaining({ deleted_at: expect.any(String) }),
    ]);
    expect(updatesFor("routine_presets")).toEqual([
      expect.objectContaining({ deleted_at: expect.any(String) }),
    ]);
  });

  it("routes permanent session and recording purges through idempotent RPCs", async () => {
    await purgeSession("session-1");
    await purgeRecording("recording-1");

    expect(h.rpcCalls).toEqual([
      { name: "purge_session", args: { p_id: "session-1" } },
      { name: "purge_recording", args: { p_id: "recording-1" } },
    ]);
  });
});
