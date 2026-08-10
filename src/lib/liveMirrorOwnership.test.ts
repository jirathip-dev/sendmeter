import { describe, it, expect } from "vitest";
import type { LiveWorkoutMessage, LiveForceMessage } from "sendlog-auth-bridge";
import {
  acceptsPacketOwner,
  hasAccountChangedSincePersisted,
  type LiveMirrorOwnershipStorage,
} from "./liveMirrorOwnership";
import {
  messageToLive,
  emptyLiveWorkoutMirrorState,
  reduceLiveWorkout,
} from "./liveWorkoutMirror";
import { emptyLiveForceMirrorState, reduceForceBeat } from "./liveForceMirror";

const ACCOUNT_A = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
const ACCOUNT_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const T0 = "2026-07-16T10:00:00.000Z";
const T1 = "2026-07-16T10:00:05.000Z";

function fakeStorage(): LiveMirrorOwnershipStorage {
  const map = new Map<string, string>();
  return {
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => void map.set(key, value),
  };
}

describe("acceptsPacketOwner", () => {
  it("accepts a packet stamped for the current account, normalizing Swift UUID casing", () => {
    expect(acceptsPacketOwner(ACCOUNT_A, ACCOUNT_A.toLowerCase(), false)).toBe(true);
    expect(acceptsPacketOwner(ACCOUNT_A, ACCOUNT_A.toLowerCase(), true)).toBe(true);
  });

  it("rejects a packet stamped for a different account regardless of transition history", () => {
    expect(acceptsPacketOwner(ACCOUNT_A, ACCOUNT_B, false)).toBe(false);
    expect(acceptsPacketOwner(ACCOUNT_A, ACCOUNT_B, true)).toBe(false);
  });

  it("accepts an unstamped (key absent) legacy packet before any account transition has occurred", () => {
    expect(acceptsPacketOwner(undefined, ACCOUNT_B, false)).toBe(true);
  });

  it("rejects an unstamped legacy packet once an account transition has occurred", () => {
    expect(acceptsPacketOwner(undefined, ACCOUNT_B, true)).toBe(false);
  });

  // Round-1 review F6: a stamp that is PRESENT but unparseable must fail
  // closed unconditionally — it claims an owner it cannot substantiate,
  // which is a stronger (and more dangerous) claim than carrying no owner at
  // all, and must never be routed into the lenient "no transition yet"
  // branch reserved for a genuinely absent key.
  it("fails closed for a present-but-malformed stamp, even before any transition", () => {
    expect(acceptsPacketOwner("", ACCOUNT_B, false)).toBe(false);
    expect(acceptsPacketOwner("   ", ACCOUNT_B, false)).toBe(false);
    expect(acceptsPacketOwner(null, ACCOUNT_B, false)).toBe(false);
  });

  it("fails closed for a present-but-malformed stamp after a transition too", () => {
    expect(acceptsPacketOwner("", ACCOUNT_B, true)).toBe(false);
    expect(acceptsPacketOwner(null, ACCOUNT_B, true)).toBe(false);
  });
});

describe("hasAccountChangedSincePersisted (round-1 review F1)", () => {
  it("a first-ever mount with nothing stored is not a transition", () => {
    const storage = fakeStorage();
    expect(hasAccountChangedSincePersisted(ACCOUNT_A, storage)).toBe(false);
  });

  it("a second mount for a DIFFERENT account is a transition — the exact signal a `useRef` alone cannot survive across an unmount/remount", () => {
    const storage = fakeStorage();
    hasAccountChangedSincePersisted(ACCOUNT_A, storage); // mount 1: signed in as A
    // The whole authed tree unmounts (sign-out) and remounts fresh for B
    // (sign-in) — a brand-new hook instance. A `useRef(false)` seeded on
    // this fresh mount could never see that A existed; the durable check
    // must supply `true` here instead.
    expect(hasAccountChangedSincePersisted(ACCOUNT_B, storage)).toBe(true);
  });

  it("a second mount for the SAME account is not a transition", () => {
    const storage = fakeStorage();
    hasAccountChangedSincePersisted(ACCOUNT_A, storage);
    expect(hasAccountChangedSincePersisted(ACCOUNT_A, storage)).toBe(false);
  });

  it("normalizes Swift UUID casing when comparing against the stored value", () => {
    const storage = fakeStorage();
    hasAccountChangedSincePersisted(ACCOUNT_A, storage);
    expect(hasAccountChangedSincePersisted(ACCOUNT_A.toLowerCase(), storage)).toBe(false);
  });

  it("a LATER relaunch under the same account (no further switch) re-trusts legacy packets again — the flag is re-derived, not latched forever", () => {
    const storage = fakeStorage();
    hasAccountChangedSincePersisted(ACCOUNT_A, storage); // mount 1
    hasAccountChangedSincePersisted(ACCOUNT_B, storage); // mount 2: the switch
    // mount 3: B relaunches again with no further switch.
    expect(hasAccountChangedSincePersisted(ACCOUNT_B, storage)).toBe(false);
  });

  it("returns false and does not throw when storage is unavailable", () => {
    expect(hasAccountChangedSincePersisted(ACCOUNT_A, null)).toBe(false);
  });

  it("returns false when storage throws on read", () => {
    const throwing: LiveMirrorOwnershipStorage = {
      getItem: () => {
        throw new Error("quota");
      },
      setItem: () => {},
    };
    expect(hasAccountChangedSincePersisted(ACCOUNT_A, throwing)).toBe(false);
  });
});

// Round-1 review F1 fix, wired end-to-end: this simulates exactly what
// `useLiveWorkout`/`useLiveForce` do — an initial value from durable
// storage, seeding the transition flag BEFORE any packet is admitted —
// across the sign-out/sign-in remount the issue's own repro describes.
describe("account transition tracking across a simulated hook remount (round-1 review F1)", () => {
  it("a legacy A packet is rejected for B after a REMOUNT, not only after an in-place prop change", () => {
    const storage = fakeStorage();
    // Mount 1: signed in as A.
    hasAccountChangedSincePersisted(ACCOUNT_A, storage);
    // Sign-out unmounts the whole authed tree; sign-in remounts it fresh for
    // B. This IS the hook's initial-value computation on that fresh mount.
    const hasHadAccountTransition = hasAccountChangedSincePersisted(ACCOUNT_B, storage);
    expect(hasHadAccountTransition).toBe(true);

    // The watch is still on a pre-#530 build and keeps beating unstamped
    // packets for A's still-running workout — the exact scenario from the
    // issue body.
    expect(acceptsPacketOwner(undefined, ACCOUNT_B, hasHadAccountTransition)).toBe(false);
  });

  it("a genuinely first-ever sign-in still trusts a legacy packet", () => {
    const storage = fakeStorage();
    const hasHadAccountTransition = hasAccountChangedSincePersisted(ACCOUNT_A, storage);
    expect(acceptsPacketOwner(undefined, ACCOUNT_A, hasHadAccountTransition)).toBe(true);
  });
});

// Round-1 review F3: each case proves the guard is load-bearing by pairing
// it with a NEGATIVE CONTROL — the reducer alone (no ownership guard) DOES
// accept the same packet, so what actually keeps it out of B's mirror is
// `acceptsPacketOwner`, not the pre-existing run/sequence cursor logic. A
// test that only asserted `acceptsPacketOwner(...) === false` in isolation
// (the round-1 shape) would still pass with the hook's guard call deleted
// entirely — these instead assert against the mirror reducers themselves.
describe("full admission pipeline: late account-A packets after B is active (round-1 review F3)", () => {
  it.each(["start", "telemetry", "phase", "count", "end"] as const)(
    "keeps a late account-A workout %s packet out of B's mirror, though the reducer alone would accept it",
    (event) => {
      const msg: LiveWorkoutMessage = {
        run_id: "account-a-run",
        sequence: 5,
        event,
        terminal: event === "end",
        account_user_id: ACCOUNT_A,
        status: event === "end" ? "ended" : "live",
        started_at: Date.parse(T0) / 1000,
        updated_at: Date.parse(T1) / 1000,
      };
      const live = messageToLive(msg, null);

      // Negative control: a fresh reducer, with no ownership guard in front
      // of it, accepts this packet outright.
      const withoutGuard = reduceLiveWorkout(emptyLiveWorkoutMirrorState(), live, "watch-direct");
      expect(withoutGuard.accepted).toBe(true);

      // With the guard in front (as the hook wires it, before `ingest` is
      // ever called): B has already lived through an account transition, so
      // this A-stamped packet must never reach the reducer at all.
      expect(acceptsPacketOwner(msg.account_user_id, ACCOUNT_B, true)).toBe(false);
    },
  );

  it.each(["start", "telemetry", "phase", "count", "end"] as const)(
    "keeps a late account-A force %s packet out of B's mirror, though the reducer alone would accept it",
    (event) => {
      const msg: LiveForceMessage = {
        run_id: "account-a-run",
        sequence: 5,
        event,
        terminal: event === "end",
        account_user_id: ACCOUNT_A,
        status: event === "end" ? "idle" : "measuring",
        kg: 10,
        peak_kg: 12,
        elapsed_ms: 500,
        session_count: 1,
        tag: "MVC",
        side: "left",
        updated_at: Date.parse(T1) / 1000,
        spark: [],
      };

      // Negative control: a fresh reducer, with no ownership guard in front
      // of it, accepts this packet outright.
      const withoutGuard = reduceForceBeat(emptyLiveForceMirrorState(), msg);
      expect(withoutGuard.accepted).toBe(true);

      // With the guard in front: B has already lived through an account
      // transition, so this A-stamped packet must never reach the reducer.
      expect(acceptsPacketOwner(msg.account_user_id, ACCOUNT_B, true)).toBe(false);
    },
  );
});
