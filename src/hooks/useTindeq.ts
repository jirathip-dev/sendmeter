import { useCallback, useEffect, useRef, useState } from "react";
import {
  activeDynamometerDriver,
  DynamometerCancelledError,
} from "../lib/dynamometer";
import type { DynamometerConnection, ForceSample } from "../lib/dynamometer";
import { reportPersistFailure } from "../lib/lostRecordings";
import { persistRecording } from "../lib/recordingQueue";
import type {
  NewTindeqRecording,
  TindeqSample,
  TindeqSide,
} from "../types";

export type TindeqStatus =
  | "unsupported"
  | "idle"
  | "connecting"
  | "connected"
  | "checking"
  | "armed"
  | "measuring";

export interface StoppedRecording {
  durationMs: number;
  peakKg: number;
  avgKg: number;
  samples: TindeqSample[];
}

// Safety cap on a single continuous recording. High enough that long holds
// (up to 240s smart-CF targets) and full guided endurance protocols never get
// cut off — it's only a runaway guard, not a normal stop.
const MAX_RECORDING_MS = 1_800_000; // 30 min
/// #173: the one device-layer lookup. Everything below talks to the
/// `DynamometerDriver` interface — service UUIDs, packet parsing and command
/// bytes all live behind it. Resolved (and probed) at module load because the
/// answer can't change at runtime, and because react-compiler lint forbids
/// impure calls in render.
const DRIVER = activeDynamometerDriver();
const AVAILABILITY = DRIVER.availability();
const FAKE_MODE =
  typeof window !== "undefined" &&
  new URLSearchParams(window.location.search).has("fake-tindeq");

export function summarize(samples: TindeqSample[]): StoppedRecording | null {
  if (samples.length === 0) return null;
  const rounded = samples.map((s) => ({
    t: Math.round(s.t),
    kg: Math.round(s.kg * 100) / 100,
  }));
  const kgs = rounded.map((s) => s.kg);
  return {
    durationMs: rounded[rounded.length - 1]!.t,
    peakKg: Math.max(...kgs),
    avgKg: Math.round((kgs.reduce((a, b) => a + b, 0) / kgs.length) * 100) / 100,
    samples: rounded,
  };
}

export function samplesThrough(
  samples: TindeqSample[],
  endMs: number | null | undefined,
): TindeqSample[] {
  return endMs == null ? samples : samples.filter((sample) => sample.t <= endMs);
}

/// What ForceView (the tag/side/session owner) knows at the moment this hook
/// unmounts — supplied via setSalvageContext, consumed only by the
/// unmount-salvage cleanup below (#106).
export interface SalvageContext {
  tag: string;
  side: TindeqSide;
  groupId: string | null;
  /// The signed-in user who captured it. Required (not optional) so a
  /// salvage can never silently fall back to null when a real user IS
  /// known — drainQueue attempts null-user entries for ANY signed-in user,
  /// and this device's throwaway-dev-account workflow makes "captured under
  /// account A, drained into account B" a real scenario, not a hypothetical
  /// one. Only the no-context-registered fallback below uses null.
  userId: string;
  /// True while ForceView's own Stop flow (handleStop/runStop) is mid-flight
  /// — that path already owns saving (or queuing, on failure) this data, so
  /// the salvage cleanup must stand down rather than double-save it.
  stopInFlight: boolean;
  /// A protocol owner may provide self-describing synchronous salvage rows.
  /// Called only after the unmount gate passes, with the still-live raw buffer.
  /// Reverse Action uses this to keep its current set/markers/metrics instead
  /// of degrading the whole run to one free-hold-shaped blob.
  /// `null` means "not this protocol" and enables generic salvage; an empty
  /// array means the protocol owned the buffer but no set had started long
  /// enough to save, so prep/rest samples must not become a fake free hold.
  buildSalvageRecordings?: (
    samples: readonly TindeqSample[],
  ) => (NewTindeqRecording & { id: string })[] | null;
}

/// Pure gate for the unmount-salvage cleanup — pulled out so the exact
/// condition is independently unit-testable. A single test on this would
/// have caught a prior, inverted version of this check. `measuring` is OR-ed
/// with `pendingInterruption` because a mid-measurement BLE drop clears
/// recordingRef before the deferred stop handler can run — a logout in that
/// same tick must still salvage (#113).
export function shouldSalvageOnUnmount(params: {
  measuring: boolean;
  pendingInterruption: boolean;
  stopInFlight: boolean;
  sampleCount: number;
}): boolean {
  return (
    (params.measuring || params.pendingInterruption) &&
    !params.stopInFlight &&
    params.sampleCount >= 2
  );
}

/// #117: note for a stop triggered by a BLE interruption. When THIS mounted
/// ForceView instance never observed measuring, the drop happened while it
/// was unmounted (tab switched) and the recovered save is a raw whole-buffer
/// blob that may overlap already-saved per-rep rows — label it (mirroring the
/// salvage path's "Recovered after sign-out") so it can't masquerade as a
/// clean pull. A mounted interruption is the normal stop path: no note.
export function interruptionNote(everMeasuredThisMount: boolean): string {
  return everMeasuredThisMount ? "" : "Recovered after connection loss";
}

/// #119: the tag/side ForceView had registered at the instant a
/// mid-measurement drop fired — i.e. the ones the user set before Start.
export interface InterruptionContext {
  tag: string;
  side: TindeqSide;
}

/// #119: narrow a registered SalvageContext down to just the label fields, at
/// DROP TIME. This must never be deferred to recovery time: a ForceView that
/// remounts to recover the buffer (the drop fired while the user was on
/// another tab) runs its own setSalvageContext effect first, re-registering a
/// fresh context whose pendingTag/pendingSide are still empty — so a late read
/// of salvageContextRef is deterministically "" again.
export function snapshotInterruption(
  ctx: SalvageContext | null | undefined,
): InterruptionContext | null {
  return ctx ? { tag: ctx.tag, side: ctx.side } : null;
}

/// #119: tag/side for an interruption-recovery save. On a remount recovery the
/// fresh mount's view state is still empty (the 0 ms deferred stop beats the
/// async tag seeding), so each field falls back to the drop-time snapshot —
/// the same pre-Start label the sign-out salvage path already writes, which is
/// the whole point of the parity fix. Live state WINS whenever it has
/// something: a mount that did seed first is at least as current as the
/// snapshot, so this is a fallback, never an override.
export function recoveredTagSide(
  live: InterruptionContext,
  snapshot: InterruptionContext | null,
): InterruptionContext {
  return {
    tag: live.tag || (snapshot?.tag ?? ""),
    side: live.side || (snapshot?.side ?? ""),
  };
}

/**
 * The app's single dynamometer connection: connection lifecycle, the live
 * sample buffer, and the recovery/salvage rules around an interrupted pull.
 *
 * Device-agnostic since #173 — it drives whatever `activeDynamometerDriver()`
 * returns (today: the Tindeq Progressor over BLE). The name is unchanged
 * because renaming it touches every consumer for no behavioural gain; rename
 * to `useDynamometer` whenever a second driver actually lands.
 */
export function useTindeq() {
  // Whether the driver's transport exists here, plus (for web BLE) whether the
  // page context permits it — the UI words the two cases differently.
  const supported = FAKE_MODE || AVAILABILITY.supported;
  const secure = AVAILABILITY.secure;

  const [status, setStatus] = useState<TindeqStatus>(
    supported && secure ? "idle" : "unsupported",
  );
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [lowBattery, setLowBattery] = useState(false);
  const [current, setCurrent] = useState(0);
  const [peak, setPeak] = useState(0);
  const [avg, setAvg] = useState(0);
  const [elapsedMs, setElapsedMs] = useState(0);
  // True while a mid-measurement BLE drop's buffer is unclaimed — the
  // reactive mirror of pendingInterruptionRef below (the ref stays because
  // the unmount-salvage cleanup must capture it synchronously). The owner
  // (ForceView) reacts by running its stop/save path — including on a
  // REMOUNT, when the drop fired while it was on another tab (#117); cleared
  // when any start/stop takes ownership of the buffer.
  const [pendingInterruption, setPendingInterruption] = useState(false);
  // #119: the tag/side captured at the instant of that drop — the fallback
  // label for the recovery save, since the recovering ForceView may be a fresh
  // mount whose own pendingTag/pendingSide are still empty. Cleared alongside
  // the claim.
  const [interruptionContext, setInterruptionContext] =
    useState<InterruptionContext | null>(null);

  const connectionRef = useRef<DynamometerConnection | null>(null);
  const samplesRef = useRef<TindeqSample[]>([]);
  const t0Ref = useRef<number | null>(null);
  // A Progressor only publishes force after startMeasuring(), so hands-free
  // arming needs a live sensor stream before the actual recording begins.
  // Keep transport streaming separate from recording ownership: pre-start
  // samples drive the trigger UI but must never be saved or salvaged.
  const streamingRef = useRef(false);
  const recordingRef = useRef(false);
  // Claim transport transitions before their first await. A quick double tap
  // must not send duplicate start/stop commands or create two fake timers.
  const streamStartInFlightRef = useRef(false);
  const armCancelInFlightRef = useRef(false);
  // #113: set on a mid-measurement BLE drop, cleared when any stop/start
  // takes ownership of the buffer; OR-ed into the salvage gate so a drop +
  // logout in the same tick still salvages (the disconnect callback clears
  // recordingRef before the deferred stop handler can run).
  const pendingInterruptionRef = useRef(false);
  const latestRef = useRef({ kg: 0, t: 0 });
  // Running mean of the current pull (sum/count over all samples) — flushed
  // to `avg` state once per frame alongside current/peak.
  const sumRef = useRef({ sum: 0, count: 0 });
  const rafRef = useRef(0);
  const fakeTimerRef = useRef(0);
  // #106: the last context ForceView registered (tag/side/groupId + whether
  // its own Stop is mid-flight) — read only by the unmount-salvage cleanup
  // below. Deliberately never cleared on ForceView's OWN unmount (an
  // ordinary tab switch, which does NOT tear this hook down — see below):
  // the last-known context is exactly what a later salvage (possibly after
  // the user left the Force tab entirely) should use.
  const salvageContextRef = useRef<(() => SalvageContext) | null>(null);
  const setSalvageContext = useCallback(
    (cb: (() => SalvageContext) | null) => {
      salvageContextRef.current = cb;
    },
    [],
  );

  // #119: claim a mid-measurement drop's buffer AND snapshot the tag/side that
  // were registered at that instant. Shared by the real disconnect callback
  // and the dev fake-drop helper below so the two can't drift — the snapshot
  // has to happen in BOTH or the recovery flow isn't browser-verifiable.
  const claimInterruption = useCallback(() => {
    setInterruptionContext(snapshotInterruption(salvageContextRef.current?.()));
    pendingInterruptionRef.current = true;
    setPendingInterruption(true);
  }, []);

  const stopRaf = useCallback(() => {
    cancelAnimationFrame(rafRef.current);
    rafRef.current = 0;
  }, []);

  // Flush latest sample into React state at most once per frame.
  const startRaf = useCallback(() => {
    const tick = () => {
      const { kg, t } = latestRef.current;
      setCurrent(kg);
      setElapsedMs(t);
      setPeak((p) => Math.max(p, kg));
      const { sum, count } = sumRef.current;
      if (count > 0) setAvg(sum / count);
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  }, []);

  // Device readings → the session buffer. `us` is a device-clock timestamp
  // whose epoch is the device's own, so the first sample of a pull sets t0 and
  // everything after it is milliseconds since then (what the DB stores).
  const handleSamples = useCallback(
    (incoming: ForceSample[]) => {
      if (!streamingRef.current) return;
      for (const s of incoming) {
        if (t0Ref.current === null) t0Ref.current = s.us;
        const t = (s.us - t0Ref.current) / 1000;
        samplesRef.current.push({ t, kg: s.kg });
        latestRef.current = { kg: s.kg, t };
        sumRef.current.sum += s.kg;
        sumRef.current.count += 1;
      }
    },
    [],
  );

  const cleanupDevice = useCallback(() => {
    streamingRef.current = false;
    recordingRef.current = false;
    stopRaf();
    clearInterval(fakeTimerRef.current);
    connectionRef.current = null;
  }, [stopRaf]);

  /// The device (or the OS) dropped the link. Shared by the driver's
  /// `onDisconnected` callback and the FAKE_MODE drop helper below so the two
  /// can never drift.
  const handleDeviceDropped = useCallback(() => {
    // keep samples so an interrupted recording can still be saved
    const wasMeasuring = recordingRef.current;
    cleanupDevice();
    setStatus("idle");
    setErrorMsg("Device disconnected");
    // Tell the owner to save the in-flight recording (samplesRef intact).
    if (wasMeasuring) claimInterruption();
  }, [cleanupDevice, claimInterruption]);

  // #106: this hook's owner is TindeqProvider, which sits ABOVE the tab
  // switch (SL-58 #5) — ForceView unmounts and remounts freely underneath it
  // as the user navigates, but THIS hook instance (and its BLE connection,
  // and samplesRef) only unmounts for one reason: the authed tree tears
  // down, i.e. App.tsx's `if (!session) return <LoginScreen />` fired. So
  // there's no tab-switch ambiguity to gate against here — unlike an
  // equivalent attempt from ForceView's own unmount, which fires on every
  // ordinary tab switch too (a prior version of this fix tried exactly that
  // and salvaged spurious duplicates as a result).
  useEffect(() => {
    return () => {
      // INVARIANT: wasMeasuring/pendingInterruption/sampleCount MUST be
      // captured here, in this SAME cleanup, BEFORE cleanupDevice() runs —
      // cleanupDevice() sets recordingRef.current = false, so reading it
      // after (or from a separate effect that might reorder relative to this
      // one) would always see "not measuring" and silently disable salvage.
      // cleanupDevice() doesn't touch pendingInterruptionRef today, but the
      // same capture-before-cleanup discipline covers it so that never
      // regresses. Don't split this cleanup or reorder these lines.
      const wasMeasuring = recordingRef.current;
      const pendingInterruption = pendingInterruptionRef.current;
      const sampleCount = samplesRef.current.length;
      const connection = connectionRef.current;
      cleanupDevice();
      if (connection) void connection.disconnect().catch(() => {});

      // No ForceView ever registered a context this session (e.g. the
      // session died while the user was on a different tab, or measuring
      // started some other way) — nothing can be "mid-Stop" in that case,
      // so fall back to a generic, tag-less, user-less recovery rather than
      // a silent full loss. `userId` is pulled out separately (rather than
      // folded into the fallback object below) so SalvageContext.userId can
      // stay a required `string` for every REGISTERED context — only this
      // no-registration fallback is allowed to pass null through to
      // enqueueRecording.
      const registered = salvageContextRef.current?.();
      const ctx = registered ?? {
        tag: "",
        side: "" as TindeqSide,
        groupId: null,
        stopInFlight: false,
        buildSalvageRecordings: undefined,
      };
      const userId: string | null = registered?.userId ?? null;
      if (
        !shouldSalvageOnUnmount({
          measuring: wasMeasuring,
          pendingInterruption,
          stopInFlight: ctx.stopInFlight,
          sampleCount,
        })
      ) {
        return;
      }
      const summary = summarize(samplesRef.current);
      if (!summary) return;
      // #269: THE synchronous store, deliberately. This is a React cleanup
      // function — it cannot await, and `samplesRef.current` is gone the moment
      // it returns, so an async write here would not "finish later", it would
      // lose the recording. `persistRecording` is the localStorage emergency
      // lane kept for exactly this call site; the main queue is IndexedDB and
      // every other caller uses `persistRecordingDurable`. The lane is drained
      // into IndexedDB by `absorbSyncLane` on the next foreground. Do not
      // "simplify" this to the async path — see the policy block in
      // recordingQueue.ts.
      let specialized: (NewTindeqRecording & { id: string })[] | null = null;
      try {
        specialized = ctx.buildSalvageRecordings?.(samplesRef.current) ?? null;
      } catch {
        // A protocol-specific builder must never turn a recoverable raw buffer
        // into total loss. Fall back to the established generic salvage row.
      }
      const salvageRows =
        specialized !== null
          ? specialized
          : [{
          id: crypto.randomUUID(),
          durationMs: summary.durationMs,
          peakKg: summary.peakKg,
          avgKg: summary.avgKg,
          // Free-hold-shaped recovery — flagged so it reads as a salvaged
          // blob rather than a normal miss, and NEVER carries a
          // protocolRunId even mid-guided-protocol: it's a raw buffer
          // slice, not a clean per-rep hold, and tagging it into a run
          // would skew SL-102's per-rep box plots/run grouping.
          note: "Recovered after sign-out",
          tag: ctx.tag,
          side: ctx.side,
          groupId: ctx.groupId,
          protocolRunId: null,
          setNo: null,
          // …and no zone either (#259), for the same reason: a raw buffer
          // slice isn't a hold performed under a protocol, so there's no
          // performed quality to record. It falls back to inference.
          zone: null,
          samples: summary.samples,
        }];
      for (const row of salvageRows) {
        const result = persistRecording(
          row,
          // null only via the no-context fallback above — a REGISTERED
          // context always carries the real signed-in user id, so a pull
          // captured under one account can never drain into another
          // (drainQueue attempts null-user entries for ANY signed-in user).
          userId,
        );
      // #264: this is the ONE path that can lose a recording with nothing
      // the user can do about it — no toast/UI is reachable from an unmount
      // cleanup, and the buffer is gone the moment this function returns.
      // reportPersistFailure is therefore the whole remedy: a Sentry event so
      // we can see it happened, plus a durable one-shot notice that App.tsx
      // surfaces on the next mount/foreground so the user learns of the loss
      // rather than discovering a missing rep in History weeks later.
        reportPersistFailure("salvage-on-unmount", result, row.samples.length);
      }
    };
  }, [cleanupDevice]);

  /// Run one command against the live connection.
  ///
  /// FAKE_MODE never has a connection at all (`?fake-tindeq` synthesizes the
  /// sample stream from a timer instead of a device), so every command is a
  /// no-op there — the pre-#173 `writeCmd` had exactly this early return. This
  /// is the seam's honest edge: fake mode is a property of the HOOK, not a
  /// driver, and turning it into one would change what "connected" means on
  /// the only path anyone can test.
  const runCommand = useCallback(
    async (fn: (c: DynamometerConnection) => Promise<void>) => {
      if (FAKE_MODE) return;
      const connection = connectionRef.current;
      if (!connection) throw new Error("Not connected");
      await fn(connection);
    },
    [],
  );

  const connect = useCallback(async () => {
    setErrorMsg(null);
    setStatus("connecting");
    if (FAKE_MODE) {
      await new Promise((r) => setTimeout(r, 400));
      setStatus("connected");
      return;
    }
    try {
      const connection = await DRIVER.connect({
        onSamples: handleSamples,
        onLowBattery: () => setLowBattery(true),
        onDisconnected: handleDeviceDropped,
      });
      connectionRef.current = connection;
      setStatus("connected");
      // Devices that report battery only when asked need the poke; ones that
      // don't report it at all leave the capability false and skip it.
      if (DRIVER.capabilities.deviceInfo) {
        await connection.refreshDeviceInfo().catch(() => {});
      }
    } catch (e) {
      cleanupDevice();
      setStatus("idle");
      // user cancelling the device chooser is not an error worth showing
      if (e instanceof DynamometerCancelledError) return;
      setErrorMsg(e instanceof Error ? e.message : "Connection failed");
    }
  }, [cleanupDevice, handleDeviceDropped, handleSamples]);

  const disconnect = useCallback(() => {
    const connection = connectionRef.current;
    cleanupDevice();
    if (connection) void connection.disconnect().catch(() => {});
    setStatus("idle");
  }, [cleanupDevice]);

  const tare = useCallback(async () => {
    try {
      // A driver without `capabilities.tare` resolves this as a no-op rather
      // than throwing, so there's nothing to branch on here.
      await runCommand((c) => c.tare());
      return true;
    } catch (e) {
      setErrorMsg(e instanceof Error ? e.message : "Tare failed");
      return false;
    }
  }, [runCommand]);

  const resetBuffer = useCallback(() => {
    samplesRef.current = [];
    t0Ref.current = null;
    latestRef.current = { kg: 0, t: 0 };
    sumRef.current = { sum: 0, count: 0 };
    setCurrent(0);
    setPeak(0);
    setAvg(0);
    setElapsedMs(0);
  }, []);

  const startFakeSamples = useCallback((profile: "workout" | "readiness" = "workout") => {
    if (!FAKE_MODE) return;
    const started = performance.now();
    fakeTimerRef.current = window.setInterval(() => {
      const t = performance.now() - started;
      // Readiness has a browser-testable unloaded baseline followed by a
      // gradual small pull. It is a hook concern (like FAKE_MODE itself), not
      // a fictional dynamometer driver capability.
      const readinessT = t % 12_000;
      const kg = profile === "readiness"
        ? readinessT < 6_000
          ? 0.04 * Math.sin(t / 80)
          : readinessT < 8_500
            ? Math.min(6, (readinessT - 6_000) / 400) + 0.04 * Math.sin(t / 80)
            : readinessT < 9_500
              ? 6 + 0.04 * Math.sin(t / 80)
              : readinessT < 11_000
                ? Math.max(0, 6 * (1 - (readinessT - 9_500) / 1_500))
                : 0.04 * Math.sin(t / 80)
        : Math.max(0, 20 + 15 * Math.sin(t / 900) + 2 * Math.sin(t / 90)) *
          (t < 500 ? t / 500 : 1);
      handleSamples([{ us: t * 1000, kg }]);
    }, 12);
  }, [handleSamples]);

  const claimNewStream = useCallback(() => {
    // A new stream resets the old buffer and voids any stale salvage claim.
    pendingInterruptionRef.current = false;
    setPendingInterruption(false);
    setInterruptionContext(null);
    resetBuffer();
    setErrorMsg(null);
  }, [resetBuffer]);

  const start = useCallback(async () => {
    if (streamingRef.current || streamStartInFlightRef.current) return;
    streamStartInFlightRef.current = true;
    claimNewStream();
    try {
      await runCommand((c) => c.startMeasuring());
      if (!FAKE_MODE && !connectionRef.current) return;
      streamingRef.current = true;
      recordingRef.current = true;
      setStatus("measuring");
      startRaf();
      startFakeSamples();
    } catch (e) {
      setErrorMsg(e instanceof Error ? e.message : "Failed to start");
    } finally {
      streamStartInFlightRef.current = false;
    }
  }, [claimNewStream, runCommand, startFakeSamples, startRaf]);

  const arm = useCallback(async () => {
    if (streamingRef.current || streamStartInFlightRef.current) return false;
    streamStartInFlightRef.current = true;
    claimNewStream();
    try {
      await runCommand((c) => c.startMeasuring());
      if (!FAKE_MODE && !connectionRef.current) return false;
      streamingRef.current = true;
      recordingRef.current = false;
      setStatus("armed");
      startRaf();
      startFakeSamples();
      return true;
    } catch (e) {
      setErrorMsg(e instanceof Error ? e.message : "Failed to arm");
      return false;
    } finally {
      streamStartInFlightRef.current = false;
    }
  }, [claimNewStream, runCommand, startFakeSamples, startRaf]);

  // Promote an already-streaming armed sensor to a real recording without a
  // second BLE command. The pre-start samples are discarded synchronously,
  // before recordingRef claims ownership, so no arming load can leak into the
  // saved force curve or a disconnect salvage.
  const beginArmedRecording = useCallback((): boolean => {
    if (!streamingRef.current || recordingRef.current) return false;
    resetBuffer();
    recordingRef.current = true;
    setStatus("measuring");
    return true;
  }, [resetBuffer]);

  // A readiness stream is live force without recording ownership. It is
  // intentionally distinct from `arm()`: hands-free observes `armed`, so
  // borrowing that state here could turn a setup test pull into a workout.
  const beginReadinessCheck = useCallback(async () => {
    if (streamingRef.current || streamStartInFlightRef.current) return false;
    streamStartInFlightRef.current = true;
    claimNewStream();
    try {
      await runCommand((c) => c.startMeasuring());
      if (!FAKE_MODE && !connectionRef.current) return false;
      streamingRef.current = true;
      recordingRef.current = false;
      setStatus("checking");
      startRaf();
      startFakeSamples("readiness");
      return true;
    } catch (e) {
      setErrorMsg(e instanceof Error ? e.message : "Failed to start setup check");
      return false;
    } finally {
      streamStartInFlightRef.current = false;
    }
  }, [claimNewStream, runCommand, startFakeSamples, startRaf]);

  const endReadinessCheck = useCallback(async () => {
    if (!streamingRef.current || recordingRef.current || armCancelInFlightRef.current) return;
    armCancelInFlightRef.current = true;
    streamingRef.current = false;
    stopRaf();
    clearInterval(fakeTimerRef.current);
    try {
      await runCommand((c) => c.stopMeasuring());
    } catch {
      // A disconnect while ending the check already stopped the stream.
    } finally {
      resetBuffer();
      setStatus(connectionRef.current || FAKE_MODE ? "connected" : "idle");
      armCancelInFlightRef.current = false;
    }
  }, [resetBuffer, runCommand, stopRaf]);

  const cancelArm = useCallback(async () => {
    if (
      !streamingRef.current ||
      recordingRef.current ||
      armCancelInFlightRef.current
    ) return;
    armCancelInFlightRef.current = true;
    streamingRef.current = false;
    stopRaf();
    clearInterval(fakeTimerRef.current);
    try {
      await runCommand((c) => c.stopMeasuring());
    } catch {
      // A disconnect while cancelling already stopped the stream.
    } finally {
      resetBuffer();
      setStatus(connectionRef.current || FAKE_MODE ? "connected" : "idle");
      armCancelInFlightRef.current = false;
    }
  }, [resetBuffer, runCommand, stopRaf]);

  const stop = useCallback(async (endMs?: number): Promise<StoppedRecording | null> => {
    // The Stop flow now owns this data (save or queue-on-failure), so the
    // salvage claim must be released — otherwise a later normal logout would
    // queue a duplicate of an already-saved pull (#113).
    pendingInterruptionRef.current = false;
    setPendingInterruption(false);
    // Released with the claim (#119). Safe because the recovery save reads the
    // snapshot BEFORE awaiting stop() — see runStop in ForceView.
    setInterruptionContext(null);
    streamingRef.current = false;
    recordingRef.current = false;
    stopRaf();
    clearInterval(fakeTimerRef.current);
    try {
      await runCommand((c) => c.stopMeasuring());
    } catch {
      // device may already be gone; the recording is still valid
    }
    setStatus(connectionRef.current || FAKE_MODE ? "connected" : "idle");
    // Hands-free release waits through a grace period before stopping, but
    // the low-force grace tail is not part of the performed hold.
    const summary = summarize(samplesThrough(samplesRef.current, endMs));
    if (summary) {
      setCurrent(0);
      setElapsedMs(summary.durationMs);
      setPeak(summary.peakKg);
      setAvg(summary.avgKg);
    }
    return summary;
  }, [stopRaf, runCommand]);

  // Auto-stop guard: cap recording length
  useEffect(() => {
    if (status !== "measuring") return;
    const id = window.setInterval(() => {
      if (latestRef.current.t >= MAX_RECORDING_MS) void stop();
    }, 1000);
    return () => clearInterval(id);
  }, [status, stop]);

  // Dev-only (#117): the fake connect() never reaches a driver, so fake mode
  // otherwise has NO way to simulate a mid-measurement drop — and the
  // interruption/recovery path would be unverifiable in a browser. Run
  // `window.__tindeqFakeDrop()` from the console; it invokes the same
  // handler the driver's `onDisconnected` does. Strictly FAKE_MODE-gated.
  //
  // #173: still named `__tindeqFakeDrop` (and gated on `?fake-tindeq`)
  // because that's the documented dev workflow and the console handle people
  // have muscle memory for — renaming it is churn, not a seam. It is
  // device-agnostic in everything but its name.
  useEffect(() => {
    if (!FAKE_MODE) return;
    const w = window as Window & { __tindeqFakeDrop?: () => void };
    w.__tindeqFakeDrop = handleDeviceDropped;
    return () => {
      delete w.__tindeqFakeDrop;
    };
  }, [handleDeviceDropped]);

  return {
    status,
    supported,
    secure,
    errorMsg,
    lowBattery,
    current,
    peak,
    avg,
    elapsedMs,
    pendingInterruption,
    interruptionContext,
    samplesRef,
    connect,
    disconnect,
    tare,
    beginReadinessCheck,
    endReadinessCheck,
    arm,
    beginArmedRecording,
    cancelArm,
    start,
    stop,
    setSalvageContext,
    fakeMode: FAKE_MODE,
    /// #173: the connected device's product name, for UI copy. The Force tab's
    /// strings are still hardcoded ("Connect Progressor" and friends) — see the
    /// comments there — so nothing reads this yet; it's the handle for whoever
    /// does that copy pass when a second driver exists.
    deviceName: DRIVER.deviceName,
    capabilities: DRIVER.capabilities,
  };
}
