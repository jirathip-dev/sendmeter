import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import {
  isFresh,
  emptyLiveForceMirrorState,
  reduceForceBeat,
  type LiveForce,
  type LiveForceMirrorState,
  type LiveForceSample,
} from "../lib/liveForceMirror";
import {
  acceptsPacketOwner,
  hasAccountChangedSincePersisted,
} from "../lib/liveMirrorOwnership";
import { subscribePluginListener } from "./pluginListener";

export type { LiveForce, LiveForceSample };

/// The watch's live Progressor session, mirrored on the phone Force tab
/// (SL-87). WatchConnectivity-only via the auth-bridge plugin — sub-second
/// and network-free, but native-only (always null in a browser) and only
/// while the phone is reachable from the watch. Device-only to verify.
export function useLiveForce(userId: string): LiveForce | null {
  const [beat, setBeat] = useState<LiveForce | null>(null);
  const mirrorRef = useRef<LiveForceMirrorState>(emptyLiveForceMirrorState());
  const activeUserIdRef = useRef(userId);
  const [renderedUserId, setRenderedUserId] = useState(userId);
  // Hide the previous account's beat on the transition render; the layout
  // effect then clears the cursor before paint and before the next listener
  // can publish a packet.
  const accountTransition = renderedUserId !== userId;
  // #530 (round-1 review F1): a `useRef` alone is inert on a real account
  // switch — this app has no in-place swap, so sign-out → sign-in is a full
  // UNMOUNT of this hook, not a `userId` prop change on a still-mounted one.
  // The initial value instead consults durable storage (survives that
  // remount); the ref then also flips true on an in-mount prop change (the
  // narrower background/foreground relay case), same as before. Evaluated
  // exactly once via `useState`'s lazy initializer — `hasAccountChangedSincePersisted`
  // both reads AND writes storage, so it must not re-run on every render.
  const [initialHasHadAccountTransition] = useState(() =>
    hasAccountChangedSincePersisted(userId),
  );
  const hasHadAccountTransitionRef = useRef(initialHasHadAccountTransition);

  if (accountTransition) {
    setRenderedUserId(userId);
    setBeat(null);
  }

  useLayoutEffect(() => {
    // #530: compare BEFORE activeUserIdRef is reassigned below — a mismatch
    // here means this run is a genuine account change, not the initial
    // mount (whose ref/prop start out equal).
    if (activeUserIdRef.current !== userId) {
      hasHadAccountTransitionRef.current = true;
    }
    activeUserIdRef.current = userId;
    mirrorRef.current = emptyLiveForceMirrorState();
  }, [userId]);

  // Staleness re-check between beats.
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const effectUserId = userId;
    let cancelled = false;
    if (!Capacitor.isNativePlatform()) return () => { cancelled = true; };
    // #485 F7: `subscribePluginListener` (see its doc comment) so a handle
    // that resolves after this effect has already cleaned up still gets
    // removed instead of leaking.
    const unsubscribe = subscribePluginListener(() =>
      SendLogAuthBridge.addListener("liveForce", (msg) => {
        if (cancelled || activeUserIdRef.current !== effectUserId) return;
        // #530: reject a packet stamped (or, per the conservative
        // mixed-version rule, un-stamped after a transition) for a different
        // account BEFORE it ever reaches reduceForceBeat. Reads the live ref
        // value (round-1 review F5), not the render-captured `effectUserId`.
        if (!acceptsPacketOwner(msg.account_user_id, activeUserIdRef.current, hasHadAccountTransitionRef.current)) {
          return;
        }
        // The ref is the authoritative cursor: event callbacks can arrive
        // faster than React renders, so a functional setState alone would
        // leave terminal/out-of-order decisions detached from the current
        // run. Mutate the ref and publish the accepted snapshot together.
        const reduced = reduceForceBeat(mirrorRef.current, msg);
        if (!reduced.accepted) return;
        mirrorRef.current = reduced.state;
        setBeat(reduced.state.beat);
      }),
    );
    const interval = setInterval(() => setNow(Date.now()), 2_000);
    return () => {
      cancelled = true;
      clearInterval(interval);
      unsubscribe();
    };
  }, [userId]);

  const visibleBeat = accountTransition ? null : beat;
  if (!visibleBeat) return null;
  if (!isFresh(visibleBeat, now)) return null;
  return visibleBeat;
}
