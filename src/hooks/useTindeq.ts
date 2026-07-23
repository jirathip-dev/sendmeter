import { useCallback, useEffect, useRef, useState } from "react";
import { BleClient } from "@capacitor-community/bluetooth-le";
import { Capacitor } from "@capacitor/core";
import { parseNotification, TINDEQ } from "../lib/tindeq-protocol";
import { enqueueRecording, loadQueue, saveQueue } from "../lib/recordingQueue";
import type { TindeqSample, TindeqSide } from "../types";

export type TindeqStatus =
  | "unsupported"
  | "idle"
  | "connecting"
  | "connected"
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
const IS_NATIVE = Capacitor.isNativePlatform();
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
}

/// Pure gate for the unmount-salvage cleanup — pulled out so the exact
/// condition (all three, ANDed) is independently unit-testable. A single
/// test on this would have caught a prior, inverted version of this check.
export function shouldSalvageOnUnmount(params: {
  measuring: boolean;
  stopInFlight: boolean;
  sampleCount: number;
}): boolean {
  return params.measuring && !params.stopInFlight && params.sampleCount >= 2;
}

/**
 * Tindeq Progressor over BleClient: Web Bluetooth in browsers, native
 * CoreBluetooth inside the Capacitor iOS app — one code path for both.
 */
export function useTindeq() {
  // Native always has BLE; web needs Web Bluetooth + secure context.
  const supported =
    FAKE_MODE ||
    IS_NATIVE ||
    (typeof navigator !== "undefined" && "bluetooth" in navigator);
  const secure =
    IS_NATIVE || typeof window === "undefined" || window.isSecureContext;

  const [status, setStatus] = useState<TindeqStatus>(
    supported && secure ? "idle" : "unsupported",
  );
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [lowBattery, setLowBattery] = useState(false);
  const [current, setCurrent] = useState(0);
  const [peak, setPeak] = useState(0);
  const [avg, setAvg] = useState(0);
  const [elapsedMs, setElapsedMs] = useState(0);
  // Bumped when the connection drops MID-MEASUREMENT — the samples are still
  // in samplesRef, and the owner (ForceView) must run its stop/save path so
  // the interrupted recording isn't lost.
  const [interruptions, setInterruptions] = useState(0);

  const deviceIdRef = useRef<string | null>(null);
  const initializedRef = useRef(false);
  const samplesRef = useRef<TindeqSample[]>([]);
  const t0Ref = useRef<number | null>(null);
  const measuringRef = useRef(false);
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

  const handleSamples = useCallback(
    (incoming: { us: number; kg: number }[]) => {
      if (!measuringRef.current) return;
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
    measuringRef.current = false;
    stopRaf();
    clearInterval(fakeTimerRef.current);
    deviceIdRef.current = null;
  }, [stopRaf]);

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
      // INVARIANT: wasMeasuring/sampleCount MUST be captured here, in this
      // SAME cleanup, BEFORE cleanupDevice() runs — cleanupDevice() sets
      // measuringRef.current = false, so reading it after (or from a
      // separate effect that might reorder relative to this one) would
      // always see "not measuring" and silently disable salvage. Don't split
      // this cleanup or reorder these two lines.
      const wasMeasuring = measuringRef.current;
      const sampleCount = samplesRef.current.length;
      const deviceId = deviceIdRef.current;
      cleanupDevice();
      if (deviceId) void BleClient.disconnect(deviceId).catch(() => {});

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
      };
      const userId: string | null = registered?.userId ?? null;
      if (
        !shouldSalvageOnUnmount({
          measuring: wasMeasuring,
          stopInFlight: ctx.stopInFlight,
          sampleCount,
        })
      ) {
        return;
      }
      const summary = summarize(samplesRef.current);
      if (!summary) return;
      const persisted = saveQueue(
        enqueueRecording(
          loadQueue(),
          {
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
            samples: summary.samples,
          },
          // null only via the no-context fallback above — a REGISTERED
          // context always carries the real signed-in user id, so a pull
          // captured under one account can never drain into another
          // (drainQueue attempts null-user entries for ANY signed-in user).
          userId,
        ),
      );
      if (!persisted) {
        // Otherwise this failure is invisible — no toast/UI is reachable
        // from an unmount cleanup, and the buffer is gone the moment this
        // function returns.
        console.warn(
          "[tindeq] salvage-on-unmount: recording captured but localStorage write failed — data lost",
        );
      }
    };
  }, [cleanupDevice]);

  const writeCmd = useCallback(async (cmd: number) => {
    if (FAKE_MODE) return;
    const deviceId = deviceIdRef.current;
    if (!deviceId) throw new Error("Not connected");
    await BleClient.write(
      deviceId,
      TINDEQ.service,
      TINDEQ.controlChar,
      new DataView(new Uint8Array([cmd]).buffer),
    );
  }, []);

  const connect = useCallback(async () => {
    setErrorMsg(null);
    setStatus("connecting");
    if (FAKE_MODE) {
      await new Promise((r) => setTimeout(r, 400));
      setStatus("connected");
      return;
    }
    try {
      if (!initializedRef.current) {
        await BleClient.initialize();
        initializedRef.current = true;
      }
      const device = await BleClient.requestDevice({
        namePrefix: TINDEQ.namePrefix,
        optionalServices: [TINDEQ.service],
      });
      await BleClient.connect(device.deviceId, () => {
        // keep samples so an interrupted recording can still be saved
        const wasMeasuring = measuringRef.current;
        cleanupDevice();
        setStatus("idle");
        setErrorMsg("Device disconnected");
        // Tell the owner to save the in-flight recording (samplesRef intact).
        if (wasMeasuring) setInterruptions((n) => n + 1);
      });
      await BleClient.startNotifications(
        device.deviceId,
        TINDEQ.service,
        TINDEQ.notifyChar,
        (dv) => {
          const frame = parseNotification(dv);
          if (frame.kind === "weight") handleSamples(frame.samples);
          else if (frame.kind === "lowBattery") setLowBattery(true);
        },
      );
      deviceIdRef.current = device.deviceId;
      setStatus("connected");
      // battery status arrives as a tag-0x02 push when low
      await writeCmd(TINDEQ.cmd.sampleBattery).catch(() => {});
    } catch (e) {
      cleanupDevice();
      setStatus("idle");
      // user cancelling the device chooser is not an error worth showing
      if (e instanceof DOMException && e.name === "NotFoundError") return;
      const msg = e instanceof Error ? e.message : "Connection failed";
      if (/cancel/i.test(msg)) return;
      setErrorMsg(msg);
    }
  }, [cleanupDevice, handleSamples, writeCmd]);

  const disconnect = useCallback(() => {
    const deviceId = deviceIdRef.current;
    cleanupDevice();
    if (deviceId) void BleClient.disconnect(deviceId).catch(() => {});
    setStatus("idle");
  }, [cleanupDevice]);

  const tare = useCallback(async () => {
    try {
      await writeCmd(TINDEQ.cmd.tare);
    } catch (e) {
      setErrorMsg(e instanceof Error ? e.message : "Tare failed");
    }
  }, [writeCmd]);

  const start = useCallback(async () => {
    samplesRef.current = [];
    t0Ref.current = null;
    latestRef.current = { kg: 0, t: 0 };
    sumRef.current = { sum: 0, count: 0 };
    setCurrent(0);
    setPeak(0);
    setAvg(0);
    setElapsedMs(0);
    setErrorMsg(null);
    try {
      await writeCmd(TINDEQ.cmd.startWeight);
      measuringRef.current = true;
      setStatus("measuring");
      startRaf();
      if (FAKE_MODE) {
        const started = performance.now();
        fakeTimerRef.current = window.setInterval(() => {
          const t = performance.now() - started;
          const kg =
            Math.max(0, 20 + 15 * Math.sin(t / 900) + 2 * Math.sin(t / 90)) *
            (t < 500 ? t / 500 : 1);
          handleSamples([{ us: t * 1000, kg }]);
        }, 12);
      }
    } catch (e) {
      setErrorMsg(e instanceof Error ? e.message : "Failed to start");
    }
  }, [writeCmd, startRaf, handleSamples]);

  const stop = useCallback(async (): Promise<StoppedRecording | null> => {
    measuringRef.current = false;
    stopRaf();
    clearInterval(fakeTimerRef.current);
    try {
      await writeCmd(TINDEQ.cmd.stop);
    } catch {
      // device may already be gone; the recording is still valid
    }
    setStatus(deviceIdRef.current || FAKE_MODE ? "connected" : "idle");
    const summary = summarize(samplesRef.current);
    if (summary) {
      setCurrent(0);
      setElapsedMs(summary.durationMs);
      setPeak(summary.peakKg);
    }
    return summary;
  }, [stopRaf, writeCmd]);

  // Auto-stop guard: cap recording length
  useEffect(() => {
    if (status !== "measuring") return;
    const id = window.setInterval(() => {
      if (latestRef.current.t >= MAX_RECORDING_MS) void stop();
    }, 1000);
    return () => clearInterval(id);
  }, [status, stop]);

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
    interruptions,
    samplesRef,
    connect,
    disconnect,
    tare,
    start,
    stop,
    setSalvageContext,
    fakeMode: FAKE_MODE,
  };
}
