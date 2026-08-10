import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import {
  acceptsPacketOwner,
  isFresh,
  emptyLiveForceMirrorState,
  reduceForceBeat,
  type LiveForce,
  type LiveForceMirrorState,
  type LiveForceSample,
} from "../lib/liveForceMirror";
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
  // #530: once this becomes true it never resets — an unstamped (pre-#530
  // watch) packet is only trusted BEFORE this hook has ever lived through an
  // account transition. See `acceptsPacketOwner`'s doc comment.
  const hasHadAccountTransitionRef = useRef(false);

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
        // account BEFORE it ever reaches reduceForceBeat.
        if (!acceptsPacketOwner(msg.account_user_id, effectUserId, hasHadAccountTransitionRef.current)) {
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
