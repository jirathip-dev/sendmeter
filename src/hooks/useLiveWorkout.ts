import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import type { LiveMirrorEvent } from "sendlog-auth-bridge";
import { supabase } from "../lib/supabase";
import { fetchLiveWorkout } from "../lib/repo";
import type { LiveWorkout } from "../types";
import { subscribePluginListener } from "./pluginListener";
import {
  STALE_MS,
  admitLiveWorkoutMessage,
  deriveLiveWorkoutSyncState,
  emptyLiveWorkoutMirrorState,
  reduceLiveWorkout,
  rowToLive,
  visibleLiveWorkout,
  type HrLog,
  type LiveHrPoint,
  type LiveWorkoutMirrorState,
  type LiveWorkoutSource,
  type LiveWorkoutSyncState,
} from "../lib/liveWorkoutMirror";
import {
  hasAccountChangedSincePersisted,
  recordStampedPacketAccepted,
} from "../lib/liveMirrorOwnership";
import {
  recordLiveMirrorTrace,
  type LiveMirrorTraceInput,
} from "../lib/liveMirrorTelemetry";

export type { LiveHrPoint };
export type { LiveWorkoutSyncState } from "../lib/liveWorkoutMirror";

export interface LiveWorkoutMirrorResult {
  row: LiveWorkout | null;
  hrLog: LiveHrPoint[];
  syncState: LiveWorkoutSyncState;
}

function traceFor(
  source: LiveWorkoutSource,
  input: Omit<LiveMirrorTraceInput, "kind" | "path"> & { event?: LiveMirrorEvent },
): void {
  recordLiveMirrorTrace({
    kind: "workout",
    path: source,
    ...input,
  });
}

/// The user's in-progress watch workout, mirrored live (SL-41): one initial
/// fetch plus a dedicated realtime channel that reads row payloads directly.
/// Deliberately NOT part of RealtimeVersionProvider — a 5s heartbeat through
/// the global version counter would refetch every card in the app every 5s.
///
/// The two transports reduce through one ref-owned state machine (#521): the
/// WatchConnectivity beat is immediate, while Supabase remains the durable
/// fallback. Duplicate/out-of-order packets and late live packets after End
/// never reach React state. #614: every accepted/rejected packet is recorded
/// into a bounded, privacy-safe telemetry ring (path + latency + reason — no
/// values) and the rendered transport state is derived from the mirror cursor
/// plus the phone clock, so a quiet link reads as paused instead of healthy.
export function useLiveWorkout(
  userId: string,
): [LiveWorkout | null, LiveHrPoint[], LiveWorkoutSyncState] {
  const [row, setRow] = useState<LiveWorkout | null>(null);
  const [hrLog, setHrLog] = useState<HrLog>({ id: "", pts: [] });
  const [now, setNow] = useState(() => Date.now());
  // #614 round-2 N3: phone-local receipt time of the last accepted row, kept
  // in state (not read off the ref at render) so the visibility gate below is
  // skew-free — the watch/DB `updatedAt` would hide a just-accepted card.
  const [lastAcceptedAtMs, setLastAcceptedAtMs] = useState(0);
  // #614: honest transport state for the visible row. Kept in state (not read
  // off the ref at render — the compiler lint forbids that) and recomputed
  // wherever the ref advances or the clock ticks.
  const [syncState, setSyncState] = useState<LiveWorkoutSyncState>("unknown");
  const mirrorRef = useRef<LiveWorkoutMirrorState>(emptyLiveWorkoutMirrorState());
  const activeUserIdRef = useRef(userId);
  const [renderedUserId, setRenderedUserId] = useState(userId);
  // #614: record a "stale" trace exactly once per run when the row ages out
  // of STALE_MS — the ring otherwise only sees packets, and a mirror that
  // went silent is the one diagnosis worth naming explicitly.
  const staleRecordedRunRef = useRef("");
  // A prop change renders once before passive effect cleanup. Hide the old
  // account immediately, then reset the ref/state in a layout effect before
  // the browser can paint or a new listener can publish data.
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
    setRow(null);
    setHrLog({ id: "", pts: [] });
    setLastAcceptedAtMs(0);
    setSyncState("unknown");
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
    // on an ownership handover (a deliberate difference from the Force
    // mirror's Swift-side design, see TindeqManager.swift). This mirror is
    // safe across an account change ONLY because a phone account change
    // always resets this exact state first: either a full remount (a fresh
    // `mirrorRef`) or this layout effect (this line). If the mirror hooks
    // are ever hoisted above the tab switch, or a future refactor keeps
    // this state alive across a `userId` change without resetting it here,
    // that assumption silently stops holding.
    mirrorRef.current = emptyLiveWorkoutMirrorState();
  }, [userId]);

  useEffect(() => {
    const effectUserId = userId;
    let cancelled = false;

    function ingest(next: LiveWorkout, source: LiveWorkoutSource, isInitial = false) {
      if (cancelled || activeUserIdRef.current !== effectUserId) return;
      const nowMs = Date.now();
      const reduced = reduceLiveWorkout(mirrorRef.current, next, source, nowMs);
      const rowAgeMs = nowMs - new Date(next.updatedAt).getTime();
      traceFor(source, {
        event: next.event,
        accepted: reduced.accepted,
        rejection: reduced.rejection,
        // #614 review F1: the initial fetch's row age is DATA age, not a
        // transport latency (a row left 'live' by #472 can be minutes old) —
        // record it as ageMs so it never pollutes the latency p95. Realtime
        // arrivals record the server-path total (watch capture → render),
        // the same span as the direct total.
        ageMs: isInitial ? rowAgeMs : undefined,
        latencyMs: isInitial ? undefined : rowAgeMs,
      });
      if (!reduced.accepted) return;
      mirrorRef.current = reduced.state;
      setRow(reduced.state.row);
      setHrLog(reduced.state.hrLog);
      setLastAcceptedAtMs(reduced.state.lastAcceptedAtMs);
      // #614: the row just advanced — reflect its transport immediately
      // rather than waiting up to 5s for the clock tick.
      setSyncState(deriveLiveWorkoutSyncState(mirrorRef.current, Date.now()));
    }

    fetchLiveWorkout()
      .then((next) => {
        if (cancelled || !next) return;
        ingest(next, "server-fallback", true);
      })
      .catch(() => {});

    const channel = supabase
      .channel(`live-workout-${userId}`)
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "live_workouts",
          filter: `user_id=eq.${userId}`,
        },
        (payload) => {
          if (payload.new && "workout_id" in payload.new) {
            ingest(rowToLive(payload.new), "server-fallback");
          }
        },
      )
      .subscribe();

    // Bluetooth-fast path (native only): the watch also beats over
    // WatchConnectivity via the auth-bridge plugin — sub-second, no network.
    // Supabase remains the durable fallback and the only path on desktop.
    //
    // #485 F7: `subscribePluginListener` removes a handle even when its async
    // registration resolves after this effect has cleaned up.
    const unsubscribeWc = Capacitor.isNativePlatform()
      ? subscribePluginListener(() =>
          SendLogAuthBridge.addListener("liveWorkout", (msg) => {
            // #530 (round-1 review F5): the ref-based active-account check
            // runs FIRST, matching `useLiveForce`.
            if (cancelled || activeUserIdRef.current !== effectUserId) return;
            // #530 round-2 review R2-F6: `admitLiveWorkoutMessage` is the
            // ONLY function this listener calls to decide whether `msg`
            // reaches state — the ownership guard lives INSIDE it, not as a
            // separate call a future edit could drop without touching this
            // listener at all.
            const admission = admitLiveWorkoutMessage(
              mirrorRef.current,
              msg,
              activeUserIdRef.current,
              hasHadAccountTransitionRef.current,
              Date.now(),
            );
            // #614: record the observation whether or not it was accepted —
            // a rejected packet is exactly the trace a diagnosis needs.
            // latencyMs is the TOTAL watch-capture → WebView span (the same
            // span the server path reports, so the two are comparable); wireMs
            // and bridgeMs break the direct path into its cross-device and
            // phone-local segments. `received_at` absent (older plugin) → no
            // segment breakdown, still a total. A missing `event` (legacy
            // watch) reads as telemetry so it is throttled like one (#614 F14).
            const nowMs = Date.now();
            traceFor("watch-direct", {
              event: msg.event ?? "telemetry",
              accepted: admission.accepted,
              rejection: admission.rejection,
              latencyMs:
                msg.updated_at !== undefined ? nowMs - msg.updated_at * 1000 : undefined,
              wireMs:
                msg.received_at !== undefined && msg.updated_at !== undefined
                  ? msg.received_at * 1000 - msg.updated_at * 1000
                  : undefined,
              bridgeMs:
                msg.received_at !== undefined ? nowMs - msg.received_at * 1000 : undefined,
            });
            if (!admission.accepted) return;
            // #530 round-2 review R2-F1: a genuinely STAMPED (not
            // legacy-absent) acceptance is positive evidence this watch has
            // caught up to the current account — close the risk window
            // both for this mount and durably, so a legacy build's
            // unstamped packets are trusted again once there's real
            // evidence there is nothing left to distrust.
            if (admission.stampedAcceptance) {
              hasHadAccountTransitionRef.current = false;
              recordStampedPacketAccepted(activeUserIdRef.current);
            }
            mirrorRef.current = admission.state;
            setRow(admission.state.row);
            setHrLog(admission.state.hrLog);
            setLastAcceptedAtMs(admission.state.lastAcceptedAtMs);
            setSyncState(deriveLiveWorkoutSyncState(mirrorRef.current, Date.now()));
          }),
        )
      : null;

    const interval = setInterval(() => {
      const atMs = Date.now();
      setNow(atMs);
      // #614: age-based honesty — a row that went quiet flips to
      // `temporarily-unreachable` (then hides) on this tick without waiting
      // for the next packet. Functional update so an unchanged state doesn't
      // trigger a redundant render.
      setSyncState((prev) => {
        const next = deriveLiveWorkoutSyncState(mirrorRef.current, atMs);
        return next === prev ? prev : next;
      });
      // #614: a live row that has aged out of STALE_MS hides (see
      // `visibleLiveWorkout`) — record that once per run so the telemetry
      // names the silence rather than just stopping. The age is DATA age
      // (ageMs), never a latency sample (#614 review F1).
      const m = mirrorRef.current;
      if (m.row && m.row.status === "live" && !m.row.terminal) {
        const age = atMs - m.lastAcceptedAtMs;
        if (age > STALE_MS && staleRecordedRunRef.current !== m.row.runId) {
          staleRecordedRunRef.current = m.row.runId;
          traceFor(m.source, {
            accepted: false,
            rejection: "stale",
            ageMs: age,
          });
        }
      }
    }, 5_000);
    return () => {
      cancelled = true;
      clearInterval(interval);
      void supabase.removeChannel(channel);
      unsubscribeWc?.();
    };
  }, [userId]);

  const [visible, series] = visibleLiveWorkout(
    accountTransition ? null : row,
    accountTransition ? { id: "", pts: [] } : hrLog,
    now,
    accountTransition ? 0 : lastAcceptedAtMs,
  );
  return [visible, series, syncState];
}
