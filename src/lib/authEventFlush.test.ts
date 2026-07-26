import { describe, expect, it } from "vitest";
import {
  authEventRows,
  flushAuthEvents,
  flushSignature,
  type AuthEventRow,
} from "./authEventFlush";
import type { AuthDiagnosticEvent } from "./authDiagnostics";

const USER = "11111111-1111-1111-1111-111111111111";

function evt(over: Partial<AuthDiagnosticEvent> = {}): AuthDiagnosticEvent {
  return {
    reason: "revoked",
    count: 1,
    firstAt: "2026-07-25T23:40:00.000Z",
    lastAt: "2026-07-26T06:50:00.000Z",
    source: "auth-state-change",
    authEvent: "SIGNED_OUT",
    build: "1.4.0 (57)",
    lastGoodAt: "2026-07-25T23:40:00.000Z",
    lastGoodExpiresAt: "2026-07-26T00:40:00.000Z",
    store: "preferences",
    ...over,
  };
}

function fakeStorage(entries: Record<string, string> = {}) {
  const map = new Map(Object.entries(entries));
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
  };
}

function recorder() {
  const batches: AuthEventRow[][] = [];
  return {
    batches,
    upsert: async (rows: AuthEventRow[]) => {
      batches.push(rows);
    },
  };
}

describe("authEventRows (issue #202)", () => {
  it("maps a ring entry to the row the migration expects", () => {
    expect(authEventRows(USER, [evt()])).toEqual([
      {
        user_id: USER,
        reason: "revoked",
        source: "auth-state-change",
        auth_event: "SIGNED_OUT",
        occurrences: 1,
        first_at: "2026-07-25T23:40:00.000Z",
        last_at: "2026-07-26T06:50:00.000Z",
        last_good_at: "2026-07-25T23:40:00.000Z",
        last_good_expires_at: "2026-07-26T00:40:00.000Z",
        app_build: "1.4.0 (57)",
        event_store: "preferences",
      },
    ]);
  });

  it("nulls the optional metadata a legacy (pre-#202) ring entry lacks", () => {
    const legacy: AuthDiagnosticEvent = {
      reason: "storage-missing",
      count: 2,
      firstAt: "2026-07-01T00:00:00.000Z",
      lastAt: "2026-07-01T01:00:00.000Z",
    };
    expect(authEventRows(USER, [legacy])[0]).toMatchObject({
      source: null,
      auth_event: null,
      app_build: null,
      last_good_at: null,
      event_store: null,
      occurrences: 2,
    });
  });

  it("dedupes on the conflict key, keeping the fuller record", () => {
    // Postgres fails an entire upsert whose payload names the same conflict
    // key twice ("cannot affect row a second time") — losing every row in the
    // batch over one collision.
    const rows = authEventRows(USER, [
      evt({ count: 1 }),
      evt({ count: 4, source: "get-session" }),
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.occurrences).toBe(4);
  });

  it("sorts oldest first so the signature is stable regardless of ring order", () => {
    const older = evt({ reason: "network-error", firstAt: "2026-07-01T00:00:00.000Z" });
    const newer = evt({ firstAt: "2026-07-25T00:00:00.000Z" });
    expect(flushSignature(authEventRows(USER, [newer, older]))).toBe(
      flushSignature(authEventRows(USER, [older, newer])),
    );
  });
});

describe("flushAuthEvents idempotency", () => {
  it("sends once, then skips an unchanged ring", async () => {
    const { batches, upsert } = recorder();
    const storage = fakeStorage();
    const events = [evt()];

    expect(await flushAuthEvents(USER, { events, storage, upsert })).toBe("flushed");
    expect(await flushAuthEvents(USER, { events, storage, upsert })).toBe("skipped");
    expect(batches).toHaveLength(1);
  });

  it("re-sends when the incident grows, so the row's count stays current", async () => {
    const { batches, upsert } = recorder();
    const storage = fakeStorage();

    await flushAuthEvents(USER, { events: [evt({ count: 1 })], storage, upsert });
    const grown = evt({ count: 2, lastAt: "2026-07-27T06:50:00.000Z" });
    expect(await flushAuthEvents(USER, { events: [grown], storage, upsert })).toBe("flushed");
    expect(batches).toHaveLength(2);
    // Same conflict key both times: the DB updates the row rather than
    // inserting a second one (unique (user_id, reason, first_at)).
    expect(batches[0]![0]!.first_at).toBe(batches[1]![0]!.first_at);
    expect(batches[1]![0]!.occurrences).toBe(2);
  });

  it("re-sends for a different user even with an identical ring", async () => {
    const { batches, upsert } = recorder();
    const storage = fakeStorage();
    const events = [evt()];
    await flushAuthEvents(USER, { events, storage, upsert });
    expect(
      await flushAuthEvents("22222222-2222-2222-2222-222222222222", {
        events,
        storage,
        upsert,
      }),
    ).toBe("flushed");
    expect(batches).toHaveLength(2);
  });

  it("does not mark as sent when the upsert fails, so the next sign-in retries", async () => {
    const storage = fakeStorage();
    const failing = async () => {
      throw new Error("network down");
    };
    expect(
      await flushAuthEvents(USER, { events: [evt()], storage, upsert: failing }),
    ).toBe("failed");

    const { batches, upsert } = recorder();
    expect(await flushAuthEvents(USER, { events: [evt()], storage, upsert })).toBe("flushed");
    expect(batches).toHaveLength(1);
  });

  it("never throws into sign-in — a rejecting upsert resolves to 'failed'", async () => {
    await expect(
      flushAuthEvents(USER, {
        events: [evt()],
        storage: fakeStorage(),
        upsert: () => Promise.reject(new Error("RLS")),
      }),
    ).resolves.toBe("failed");
  });

  it("survives storage that throws on both read and write", async () => {
    const { batches, upsert } = recorder();
    const throwing = {
      getItem() {
        throw new DOMException("quota", "QuotaExceededError");
      },
      setItem() {
        throw new DOMException("quota", "QuotaExceededError");
      },
    };
    expect(
      await flushAuthEvents(USER, { events: [evt()], storage: throwing, upsert }),
    ).toBe("flushed");
    expect(batches).toHaveLength(1);
  });

  it("does nothing on an empty ring", async () => {
    const { batches, upsert } = recorder();
    expect(
      await flushAuthEvents(USER, { events: [], storage: fakeStorage(), upsert }),
    ).toBe("empty");
    expect(batches).toHaveLength(0);
  });
});
