import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import {
  admitLiveForceMessage,
  isFresh,
  emptyLiveForceMirrorState,
  type LiveForce,
  type LiveForceMirrorState,
  type LiveForceSample,
} from "../lib/liveForceMirror";
import {
  hasAccountChangedSincePersisted,
  recordStampedPacketAccepted,
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
  // narrower background/foreground relay case), same as before.
  // `hasAccountChangedSincePersisted` is a PURE read (round-2 review
  // R2-F1/R2-F4 — the write moved to `useAuth.ts`'s `onSession`, the single
  // auth-boundary owner), so evaluating it more than once (a StrictMode
  // double-invoked lazy initializer, or any other extra render) is harmless;
  // `useState`'s lazy form is used only to avoid a redundant read.
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
    // #530 round-2 review R2-F3: resetting the cursor here — synchronously,
    // before any listener installed for the NEW `userId` can publish — is
    // what makes it safe that a beat's run/sequence identity never rotates
    // on an ownership handover on the Swift side (see
    // `currentForceMirrorOwnerUserId` in TindeqManager.swift). This mirror
    // is safe across an account change ONLY because a phone account change
    // always resets this exact state first: either a full remount (a fresh
    // `mirrorRef`) or this layout effect (this line). If the mirror hooks
    // are ever hoisted above the tab switch, or a future refactor keeps
    // this state alive across a `userId` change without resetting it here,
    // that assumption silently stops holding.
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
        // #530 round-2 review R2-F6: `admitLiveForceMessage` is the ONLY
        // function this listener calls to decide whether `msg` reaches
        // state — the ownership guard lives INSIDE it, not as a separate
        // call a future edit could drop without touching this listener at
        // all. Reads the live ref value (round-1 review F5), not the
        // render-captured `effectUserId`.
        const admission = admitLiveForceMessage(
          mirrorRef.current,
          msg,
          activeUserIdRef.current,
          hasHadAccountTransitionRef.current,
        );
        if (!admission.accepted) return;
        // #530 round-2 review R2-F1: a genuinely STAMPED (not
        // legacy-absent) acceptance is positive evidence this watch has
        // caught up to the current account — close the risk window both
        // for this mount and durably.
        if (admission.stampedAcceptance) {
          hasHadAccountTransitionRef.current = false;
          recordStampedPacketAccepted(activeUserIdRef.current);
        }
        // The ref is the authoritative cursor: event callbacks can arrive
        // faster than React renders, so a functional setState alone would
        // leave terminal/out-of-order decisions detached from the current
        // run. Mutate the ref and publish the accepted snapshot together.
        mirrorRef.current = admission.state;
        setBeat(admission.state.beat);
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
