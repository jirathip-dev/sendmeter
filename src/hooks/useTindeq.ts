import { useCallback, useEffect, useRef, useState } from "react";
import { parseNotification, TINDEQ } from "../lib/tindeq-protocol";
import type { TindeqSample } from "../types";

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

const MAX_RECORDING_MS = 120_000;
const FAKE_MODE =
  typeof window !== "undefined" &&
  new URLSearchParams(window.location.search).has("fake-tindeq");

function summarize(samples: TindeqSample[]): StoppedRecording | null {
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

export function useTindeq() {
  const supported = FAKE_MODE || (typeof navigator !== "undefined" && "bluetooth" in navigator);
  const secure = typeof window === "undefined" || window.isSecureContext;

  const [status, setStatus] = useState<TindeqStatus>(
    supported && secure ? "idle" : "unsupported",
  );
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [lowBattery, setLowBattery] = useState(false);
  const [current, setCurrent] = useState(0);
  const [peak, setPeak] = useState(0);
  const [elapsedMs, setElapsedMs] = useState(0);

  const deviceRef = useRef<BluetoothDevice | null>(null);
  const controlRef = useRef<BluetoothRemoteGATTCharacteristic | null>(null);
  const notifyRef = useRef<BluetoothRemoteGATTCharacteristic | null>(null);
  const samplesRef = useRef<TindeqSample[]>([]);
  const t0Ref = useRef<number | null>(null);
  const measuringRef = useRef(false);
  const latestRef = useRef({ kg: 0, t: 0 });
  const rafRef = useRef(0);
  const fakeTimerRef = useRef(0);

  const stopRaf = useCallback(() => {
    cancelAnimationFrame(rafRef.current);
    rafRef.current = 0;
  }, []);

  // Flush latest sample into React state at most once per frame; auto-stop at cap.
  const startRaf = useCallback(() => {
    const tick = () => {
      const { kg, t } = latestRef.current;
      setCurrent(kg);
      setElapsedMs(t);
      setPeak((p) => Math.max(p, kg));
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
      }
    },
    [],
  );

  const cleanupDevice = useCallback(() => {
    measuringRef.current = false;
    stopRaf();
    clearInterval(fakeTimerRef.current);
    controlRef.current = null;
    notifyRef.current = null;
    deviceRef.current = null;
  }, [stopRaf]);

  useEffect(() => {
    return () => {
      const device = deviceRef.current;
      cleanupDevice();
      device?.gatt?.disconnect();
    };
  }, [cleanupDevice]);

  const writeCmd = useCallback(async (cmd: number) => {
    if (FAKE_MODE) return;
    const c = controlRef.current;
    if (!c) throw new Error("Not connected");
    await c.writeValue(new Uint8Array([cmd]));
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
      const device = await navigator.bluetooth.requestDevice({
        filters: [{ namePrefix: TINDEQ.namePrefix }],
        optionalServices: [TINDEQ.service],
      });
      device.addEventListener("gattserverdisconnected", () => {
        // keep samples so an interrupted recording can still be saved
        cleanupDevice();
        setStatus("idle");
        setErrorMsg("Device disconnected");
      });
      const gatt = await device.gatt!.connect();
      const service = await gatt.getPrimaryService(TINDEQ.service);
      const [notify, control] = await Promise.all([
        service.getCharacteristic(TINDEQ.notifyChar),
        service.getCharacteristic(TINDEQ.controlChar),
      ]);
      await notify.startNotifications();
      notify.addEventListener("characteristicvaluechanged", (e) => {
        const dv = (e.target as BluetoothRemoteGATTCharacteristic).value;
        if (!dv) return;
        const frame = parseNotification(dv);
        if (frame.kind === "weight") handleSamples(frame.samples);
        else if (frame.kind === "lowBattery") setLowBattery(true);
      });
      deviceRef.current = device;
      controlRef.current = control;
      notifyRef.current = notify;
      setStatus("connected");
    } catch (e) {
      cleanupDevice();
      setStatus("idle");
      // user cancelling the chooser is not an error worth showing
      if (e instanceof DOMException && e.name === "NotFoundError") return;
      setErrorMsg(e instanceof Error ? e.message : "Connection failed");
    }
  }, [cleanupDevice, handleSamples]);

  const disconnect = useCallback(() => {
    const device = deviceRef.current;
    cleanupDevice();
    device?.gatt?.disconnect();
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
    setCurrent(0);
    setPeak(0);
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
    setStatus(deviceRef.current || FAKE_MODE ? "connected" : "idle");
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
    elapsedMs,
    samplesRef,
    connect,
    disconnect,
    tare,
    start,
    stop,
    fakeMode: FAKE_MODE,
  };
}
