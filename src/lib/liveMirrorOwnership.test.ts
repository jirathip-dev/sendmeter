import { describe, it, expect } from "vitest";
import type { LiveWorkoutMessage, LiveForceMessage } from "sendlog-auth-bridge";
import {
  acceptsPacketOwner,
  hasAccountChangedSincePersisted,
  recordAuthenticatedAccountForLiveMirror,
  recordStampedPacketAccepted,
  type LiveMirrorOwnershipStorage,
} from "./liveMirrorOwnership";
import {
  admitLiveWorkoutMessage,
  emptyLiveWorkoutMirrorState,
  messageToLive,
  reduceLiveWorkout,
} from "./liveWorkoutMirror";
import {
  admitLiveForceMessage,
  emptyLiveForceMirrorState,
  reduceForceBeat,
} from "./liveForceMirror";

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

// Round-2 review R2-F1: the writer (`recordAuthenticatedAccountForLiveMirror`,
// called once by `useAuth.ts`'s `onSession`) and the reader
// (`hasAccountChangedSincePersisted`, called by any number of mirror hooks)
// are now separate functions on separate storage keys. Round-1's version
// conflated them — `hasAccountChangedSincePersisted` itself compared AND
// overwrote the stored value, so the FIRST mirror to read it consumed the
// signal for every mirror after it. These tests pin the reader as genuinely
// non-destructive.
describe("recordAuthenticatedAccountForLiveMirror + hasAccountChangedSincePersisted (round-2 review R2-F1)", () => {
  it("a first-ever recorded account is not a transition", () => {
    const storage = fakeStorage();
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, storage);
    expect(hasAccountChangedSincePersisted(ACCOUNT_A, storage)).toBe(false);
  });

  it("recording a DIFFERENT account than the last one latches a transition", () => {
    const storage = fakeStorage();
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, storage); // signed in as A
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_B, storage); // sign-out/sign-in as B
    expect(hasAccountChangedSincePersisted(ACCOUNT_B, storage)).toBe(true);
  });

  it("recording the SAME account again (a token refresh, not a switch) is not a transition", () => {
    const storage = fakeStorage();
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, storage);
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, storage);
    expect(hasAccountChangedSincePersisted(ACCOUNT_A, storage)).toBe(false);
  });

  it("normalizes Swift UUID casing on both the write and the read", () => {
    const storage = fakeStorage();
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, storage);
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_B.toUpperCase(), storage);
    expect(hasAccountChangedSincePersisted(ACCOUNT_B, storage)).toBe(true);
  });

  // The round-1 regression, reproduced directly: reading must not consume
  // the signal. This is exactly what round-1's version got wrong — it used
  // ONE function for both, so the act of a mirror hook checking the flag
  // was indistinguishable from the flag having been "handled".
  it("READING the transition flag never mutates it — repeated reads all see the same answer", () => {
    const storage = fakeStorage();
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, storage);
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_B, storage);

    expect(hasAccountChangedSincePersisted(ACCOUNT_B, storage)).toBe(true);
    expect(hasAccountChangedSincePersisted(ACCOUNT_B, storage)).toBe(true);
    expect(hasAccountChangedSincePersisted(ACCOUNT_B, storage)).toBe(true);
  });

  // Fails CLOSED (round-2 review R2-F5): unreadable/unavailable storage must
  // not silently disable the privacy boundary.
  it("hasAccountChangedSincePersisted fails closed (true) when storage is unavailable", () => {
    expect(hasAccountChangedSincePersisted(ACCOUNT_A, null)).toBe(true);
  });

  it("hasAccountChangedSincePersisted fails closed (true) when storage throws on read", () => {
    const throwing: LiveMirrorOwnershipStorage = {
      getItem: () => {
        throw new Error("quota");
      },
      setItem: () => {},
    };
    expect(hasAccountChangedSincePersisted(ACCOUNT_A, throwing)).toBe(true);
  });

  it("recordAuthenticatedAccountForLiveMirror does not throw when storage is unavailable or throws", () => {
    expect(() => recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, null)).not.toThrow();
    const throwing: LiveMirrorOwnershipStorage = {
      getItem: () => {
        throw new Error("quota");
      },
      setItem: () => {
        throw new Error("quota");
      },
    };
    expect(() => recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, throwing)).not.toThrow();
  });
});

// The exact empirical repro from the round-2 review: three mirror hooks
// (Workout, Force, History all use `useLiveWorkout`/`useLiveForce`, and tabs
// mount conditionally) each consulting the durable signal after ONE
// account-boundary write. Round-1's conflated read/write made only the
// FIRST of these `true`; every later one read `false` because reading it
// once already overwrote the stored value with the current account.
describe("R2-F1 repro: multiple mirror mounts under the same post-switch account", () => {
  it("every mirror that mounts after the switch sees the transition, not just the first", () => {
    const storage = fakeStorage();
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, storage); // signed in as A
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_B, storage); // the switch, recorded ONCE

    // Three separate mirror mounts under B — e.g. Force tab opened first,
    // then Workout, then History — each an independent `hasAccountChangedSincePersisted`
    // call, none of which is also a write.
    const mountResults = [
      hasAccountChangedSincePersisted(ACCOUNT_B, storage),
      hasAccountChangedSincePersisted(ACCOUNT_B, storage),
      hasAccountChangedSincePersisted(ACCOUNT_B, storage),
    ];

    expect(mountResults).toEqual([true, true, true]);
  });

  it("a legacy A packet is rejected on EVERY one of those mounts, not just the first", () => {
    const storage = fakeStorage();
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, storage);
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_B, storage);

    for (let mount = 0; mount < 3; mount++) {
      const hasHadAccountTransition = hasAccountChangedSincePersisted(ACCOUNT_B, storage);
      expect(acceptsPacketOwner(undefined, ACCOUNT_B, hasHadAccountTransition)).toBe(false);
    }
  });
});

// The clearing half of the design (round-2 review R2-F1's "stronger still"
// suggestion): once the watch has PROVEN it caught up — a genuinely stamped
// packet accepted for the current account — the risk window closes and a
// later mount trusts legacy packets again.
describe("recordStampedPacketAccepted", () => {
  it("clears the transition marker for the account that was just proven", () => {
    const storage = fakeStorage();
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_A, storage);
    recordAuthenticatedAccountForLiveMirror(ACCOUNT_B, storage);
    expect(hasAccountChangedSincePersisted(ACCOUNT_B, storage)).toBe(true);

    recordStampedPacketAccepted(ACCOUNT_B, storage);

    expect(hasAccountChangedSincePersisted(ACCOUNT_B, storage)).toBe(false);
  });

  it("does not throw when storage is unavailable or throws", () => {
    expect(() => recordStampedPacketAccepted(ACCOUNT_A, null)).not.toThrow();
    const throwing: LiveMirrorOwnershipStorage = {
      getItem: () => {
        throw new Error("quota");
      },
      setItem: () => {
        throw new Error("quota");
      },
    };
    expect(() => recordStampedPacketAccepted(ACCOUNT_A, throwing)).not.toThrow();
  });
});

// Round-1 review F3, closed further by round-2 review R2-F6: these no
// longer hand-compose `acceptsPacketOwner` + the reducer inline — they call
// `admitLiveWorkoutMessage`/`admitLiveForceMessage`, the EXACT same
// functions `useLiveWorkout`/`useLiveForce` call as their entire packet
// handler. Deleting the ownership guard from inside either admit function
// (the only way a hook could lose the guard, since neither hook composes it
// separately any more) fails these tests directly. Each case still pairs
// with a NEGATIVE CONTROL — the reducer alone accepts the same packet — so
// the guard is proven load-bearing, not redundant with the run/sequence
// cursor.
describe("full admission pipeline: late account-A packets after B is active", () => {
  it.each(["start", "telemetry", "phase", "count", "end"] as const)(
    "keeps a late account-A workout %s packet out of B's mirror via admitLiveWorkoutMessage, though the reducer alone would accept it",
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

      // Negative control: a fresh reducer, with no ownership guard in front
      // of it, accepts this packet outright.
      const live = messageToLive(msg, null);
      const withoutGuard = reduceLiveWorkout(emptyLiveWorkoutMirrorState(), live, "watch-direct");
      expect(withoutGuard.accepted).toBe(true);

      // With the guard: this is the ACTUAL function `useLiveWorkout` calls.
      // B has already lived through an account transition, so this
      // A-stamped packet must never reach the reducer at all.
      const admission = admitLiveWorkoutMessage(
        emptyLiveWorkoutMirrorState(),
        msg,
        ACCOUNT_B,
        true,
      );
      expect(admission.accepted).toBe(false);
      expect(admission.stampedAcceptance).toBe(false);
      expect(admission.state).toEqual(emptyLiveWorkoutMirrorState());
    },
  );

  it.each(["start", "telemetry", "phase", "count", "end"] as const)(
    "keeps a late account-A force %s packet out of B's mirror via admitLiveForceMessage, though the reducer alone would accept it",
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

      // With the guard: the ACTUAL function `useLiveForce` calls.
      const admission = admitLiveForceMessage(
        emptyLiveForceMirrorState(),
        msg,
        ACCOUNT_B,
        true,
      );
      expect(admission.accepted).toBe(false);
      expect(admission.stampedAcceptance).toBe(false);
      expect(admission.state).toEqual(emptyLiveForceMirrorState());
    },
  );

  it("admits a genuinely current-account workout packet and reports stampedAcceptance", () => {
    const msg: LiveWorkoutMessage = {
      run_id: "account-b-run",
      sequence: 1,
      event: "start",
      terminal: false,
      account_user_id: ACCOUNT_B,
      status: "live",
      started_at: Date.parse(T0) / 1000,
      updated_at: Date.parse(T1) / 1000,
    };
    const admission = admitLiveWorkoutMessage(emptyLiveWorkoutMirrorState(), msg, ACCOUNT_B, true);
    expect(admission.accepted).toBe(true);
    expect(admission.stampedAcceptance).toBe(true);
    expect(admission.state.row?.runId).toBe("account-b-run");
  });

  it("admits a genuinely current-account force packet and reports stampedAcceptance", () => {
    const msg: LiveForceMessage = {
      run_id: "account-b-run",
      sequence: 1,
      event: "start",
      terminal: false,
      account_user_id: ACCOUNT_B,
      status: "measuring",
      kg: 5,
      peak_kg: 5,
      elapsed_ms: 100,
      session_count: 0,
      tag: "MVC",
      side: "left",
      updated_at: Date.parse(T1) / 1000,
      spark: [],
    };
    const admission = admitLiveForceMessage(emptyLiveForceMirrorState(), msg, ACCOUNT_B, true);
    expect(admission.accepted).toBe(true);
    expect(admission.stampedAcceptance).toBe(true);
    expect(admission.state.beat?.runId).toBe("account-b-run");
  });

  it("admits an unstamped legacy packet with stampedAcceptance=false when no transition has occurred", () => {
    const msg: LiveForceMessage = {
      sequence: 1,
      event: "start",
      terminal: false,
      status: "measuring",
      kg: 5,
      peak_kg: 5,
      elapsed_ms: 100,
      session_count: 0,
      tag: "MVC",
      side: "left",
      updated_at: Date.parse(T1) / 1000,
      spark: [],
    };
    const admission = admitLiveForceMessage(emptyLiveForceMirrorState(), msg, ACCOUNT_B, false);
    expect(admission.accepted).toBe(true);
    expect(admission.stampedAcceptance).toBe(false);
  });
});
