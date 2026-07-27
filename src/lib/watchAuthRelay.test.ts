import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Session } from "@supabase/supabase-js";

/// The relay is native-only, so both mocks have to be in place before the
/// module under test is imported (it reads `isNativePlatform()` at load).
vi.mock("@capacitor/core", () => ({
  Capacitor: { isNativePlatform: () => true },
}));

const remove = vi.fn(async () => {});
const setSession = vi.fn<(opts: Record<string, unknown>) => Promise<void>>();
const clearSession = vi.fn<() => Promise<void>>();
const addListener =
  vi.fn<(event: string, handler: () => void) => Promise<{ remove: () => Promise<void> }>>();
addListener.mockResolvedValue({ remove });

vi.mock("sendlog-auth-bridge", () => ({
  SendLogAuthBridge: { setSession, clearSession, addListener },
}));

const { onWatchSessionRequest, relaySessionToWatch } = await import(
  "./watchAuthRelay"
);

function session(overrides: Partial<Session> = {}): Session {
  return {
    access_token: "eyJhbGciOiJIUzI1NiJ9.payload.sig",
    refresh_token: "rt-226-the-one-that-got-replayed",
    expires_at: 1_700_003_600,
    token_type: "bearer",
    expires_in: 3600,
    user: { id: "11111111-2222-3333-4444-555555555555" },
    ...overrides,
  } as Session;
}

beforeEach(() => {
  setSession.mockClear();
  clearSession.mockClear();
  addListener.mockClear();
  remove.mockClear();
});

describe("relaySessionToWatch (issue #265)", () => {
  it("never puts a refresh token on the wire", () => {
    // THE invariant. #196 enforced "the watch must not refresh" by convention
    // inside the watch, and it silently regressed; this pins the property one
    // level up, where it is structural — a credential that is never sent
    // cannot be replayed by any watch build, including one several TestFlight
    // releases old.
    relaySessionToWatch(session());
    const payload = setSession.mock.calls[0]![0];
    expect(Object.keys(payload).sort()).toEqual([
      "accessToken",
      "expiresAt",
      "userId",
    ]);
    expect(JSON.stringify(payload)).not.toContain("rt-226");
  });

  it("relays the access token, its expiry and the user id", () => {
    relaySessionToWatch(session());
    expect(setSession).toHaveBeenCalledWith({
      accessToken: "eyJhbGciOiJIUzI1NiJ9.payload.sig",
      expiresAt: 1_700_003_600,
      userId: "11111111-2222-3333-4444-555555555555",
    });
  });

  it("treats a missing expiry as 0 rather than omitting it", () => {
    // The watch prefers the token's own `exp` claim, but a 0 here must read as
    // "already expired", never as "unknown, assume fine".
    relaySessionToWatch(session({ expires_at: undefined }));
    expect(setSession.mock.calls[0]![0]).toMatchObject({ expiresAt: 0 });
  });

  it("clears the watch on sign-out", () => {
    relaySessionToWatch(null);
    expect(clearSession).toHaveBeenCalledOnce();
    expect(setSession).not.toHaveBeenCalled();
  });

  it("asks for guaranteed delivery only when answering a pull (#266)", () => {
    // A push happens on every foreground; queueing each one with
    // transferUserInfo would build a backlog of dead tokens for a watch in a
    // drawer. A pull means the watch is actively waiting.
    relaySessionToWatch(session());
    expect(setSession.mock.calls[0]![0]).not.toHaveProperty("guaranteed");

    relaySessionToWatch(session(), { guaranteed: true });
    expect(setSession.mock.calls[1]![0]).toMatchObject({ guaranteed: true });
  });
});

describe("onWatchSessionRequest (issue #266)", () => {
  it("returns the listener handle so it can be detached", async () => {
    // It used to discard it, which is why `useAuth`'s cleanup could not remove
    // this listener while it removed the other three.
    const handle = await onWatchSessionRequest(() => {});
    expect(addListener).toHaveBeenCalledWith(
      "sessionRequested",
      expect.any(Function),
    );
    handle?.remove();
    expect(remove).toHaveBeenCalledOnce();
  });
});
