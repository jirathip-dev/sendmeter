/// Runs the `DynamometerDriver` contract (`./contract.ts`) against:
///   1. the real Tindeq driver, with BleClient mocked — proving the shipped
///      driver satisfies the interface, including real Progressor packet bytes
///      going in one end and `{us, kg}` coming out the other;
///   2. a stub driver with every capability, and
///   3. a stub driver with NONE — the seam's real proof: the same consumer
///      assertions drive a device that isn't a Tindeq and doesn't pretend to
///      be one. Hardware for a genuine second device is what #173 is blocked
///      on; the seam itself is not.

import { beforeEach, describe, expect, it, vi } from "vitest";
import { BleClient } from "@capacitor-community/bluetooth-le";
import { runDriverContract } from "./contract";
import type { DriverContractHarness } from "./contract";
import {
  DynamometerCancelledError,
  type DynamometerCapabilities,
  type DynamometerConnection,
  type DynamometerDriver,
  type DynamometerListener,
  type ForceSample,
} from "./types";
import { TINDEQ_DRIVER_ID, tindeqDriver } from "./tindeq";
import { TINDEQ } from "./tindeq-protocol";
import { activeDynamometerDriver, listDynamometerDrivers } from "./index";

// ─── 1. the real Tindeq driver over a mocked BLE transport ──────────────────

type BleEvent = { kind: "write"; byte: number } | { kind: "disconnect" };

const ble = vi.hoisted(() => ({
  notify: null as ((dv: DataView) => void) | null,
  onDrop: null as (() => void) | null,
  events: [] as BleEvent[],
  cancelNext: false,
}));

vi.mock("@capacitor-community/bluetooth-le", () => ({
  BleClient: {
    initialize: () => Promise.resolve(),
    requestDevice: () => {
      if (ble.cancelNext) {
        ble.cancelNext = false;
        // Exactly what Chrome throws when the user closes the chooser.
        return Promise.reject(
          new DOMException("User cancelled the requestDevice() chooser.", "NotFoundError"),
        );
      }
      return Promise.resolve({ deviceId: "AA:BB:CC", name: "Progressor_1234" });
    },
    connect: (_id: string, onDisconnect: () => void) => {
      ble.onDrop = onDisconnect;
      return Promise.resolve();
    },
    startNotifications: (
      _id: string,
      _svc: string,
      _char: string,
      cb: (dv: DataView) => void,
    ) => {
      ble.notify = cb;
      return Promise.resolve();
    },
    write: (_id: string, _svc: string, _char: string, dv: DataView) => {
      ble.events.push({ kind: "write", byte: dv.getUint8(0) });
      return Promise.resolve();
    },
    disconnect: () => {
      ble.events.push({ kind: "disconnect" });
      return Promise.resolve();
    },
  },
}));

/// Encodes a real Progressor weight notification: [0x01][len][(f32 kg, u32 µs)…].
function weightFrame(samples: ForceSample[]): DataView {
  const payload = new ArrayBuffer(samples.length * 8);
  const pv = new DataView(payload);
  samples.forEach((s, i) => {
    pv.setFloat32(i * 8, s.kg, true);
    pv.setUint32(i * 8 + 4, s.us, true);
  });
  return new DataView(
    new Uint8Array([0x01, payload.byteLength, ...new Uint8Array(payload)]).buffer,
  );
}

const COMMAND_NAMES: Record<number, string> = {
  [TINDEQ.cmd.startWeight]: "start",
  [TINDEQ.cmd.stop]: "stop",
  [TINDEQ.cmd.tare]: "tare",
  [TINDEQ.cmd.sampleBattery]: "deviceInfo",
};

function tindeqHarness(): DriverContractHarness {
  ble.notify = null;
  ble.onDrop = null;
  ble.events = [];
  ble.cancelNext = false;
  return {
    driver: tindeqDriver,
    emitSamples: (samples) => ble.notify?.(weightFrame(samples)),
    emitLowBattery: () => ble.notify?.(new DataView(new Uint8Array([0x02, 0x00]).buffer)),
    emitDrop: () => ble.onDrop?.(),
    commands: () =>
      ble.events.map((e: BleEvent) =>
        e.kind === "disconnect" ? "disconnect" : (COMMAND_NAMES[e.byte] ?? `0x${e.byte.toString(16)}`),
      ),
    simulateCancel: () => {
      ble.cancelNext = true;
    },
  };
}

runDriverContract("Tindeq Progressor (BLE mocked)", tindeqHarness);

// ─── 2 & 3. stub drivers — no hardware, no Tindeq assumptions ───────────────

/// A driver for a device that doesn't exist. Its only job is to prove the
/// interface is implementable by something that is not a Progressor: no BLE,
/// no µs device clock of its own, and (in the second configuration) none of
/// the optional capabilities.
function stubHarness(capabilities: DynamometerCapabilities): () => DriverContractHarness {
  return () => {
    let listener: DynamometerListener | null = null;
    let cancelNext = false;
    const commands: string[] = [];

    const connection: DynamometerConnection = {
      driverId: "stub",
      startMeasuring: async () => {
        commands.push("start");
      },
      stopMeasuring: async () => {
        commands.push("stop");
      },
      tare: async () => {
        if (!capabilities.tare) return; // capability absent ⇒ no-op, not a throw
        commands.push("tare");
      },
      refreshDeviceInfo: async () => {
        if (!capabilities.deviceInfo) return;
        commands.push("deviceInfo");
      },
      disconnect: async () => {
        commands.push("disconnect");
        listener = null;
      },
    };

    const driver: DynamometerDriver = {
      id: "stub",
      deviceName: "Stub Dynamometer",
      capabilities,
      availability: () => ({ supported: true, secure: true }),
      connect: async (l) => {
        if (cancelNext) {
          cancelNext = false;
          throw new DynamometerCancelledError();
        }
        listener = l;
        return connection;
      },
    };

    return {
      driver,
      emitSamples: (samples) => listener?.onSamples(samples),
      emitLowBattery: () => listener?.onLowBattery(),
      emitDrop: () => listener?.onDisconnected(),
      commands: () => commands,
      simulateCancel: () => {
        cancelNext = true;
      },
    };
  };
}

runDriverContract(
  "stub driver, full capabilities",
  stubHarness({ tare: true, lowBatteryWarning: true, deviceInfo: true }),
);

runDriverContract(
  "stub driver, no optional capabilities",
  stubHarness({ tare: false, lowBatteryWarning: false, deviceInfo: false }),
);

// ─── Tindeq-specific wiring the generic contract can't assert ───────────────

describe("Tindeq driver specifics", () => {
  beforeEach(() => {
    ble.notify = null;
    ble.onDrop = null;
    ble.events = [];
    ble.cancelNext = false;
  });

  it("is the driver the app resolves to", () => {
    expect(activeDynamometerDriver().id).toBe(TINDEQ_DRIVER_ID);
    expect(listDynamometerDrivers().map((d) => d.id)).toContain(TINDEQ_DRIVER_ID);
  });

  it("maps each connection method onto the documented Progressor command byte", async () => {
    const conn = await tindeqDriver.connect({
      onSamples: () => {},
      onLowBattery: () => {},
      onDisconnected: () => {},
    });
    await conn.tare();
    await conn.startMeasuring();
    await conn.stopMeasuring();
    await conn.refreshDeviceInfo();
    expect(ble.events).toEqual([
      { kind: "write", byte: 0x64 },
      { kind: "write", byte: 0x65 },
      { kind: "write", byte: 0x66 },
      { kind: "write", byte: 0x6f },
    ]);
  });

  it("ignores frames that are neither weight nor low-battery", async () => {
    const onSamples = vi.fn();
    const onLowBattery = vi.fn();
    await tindeqDriver.connect({ onSamples, onLowBattery, onDisconnected: () => {} });
    // tag 0x00 = a command response; tag 0x7f = unknown.
    ble.notify?.(new DataView(new Uint8Array([0x00, 0x02, 0xaa, 0xbb]).buffer));
    ble.notify?.(new DataView(new Uint8Array([0x7f, 0x00]).buffer));
    expect(onSamples).not.toHaveBeenCalled();
    expect(onLowBattery).not.toHaveBeenCalled();
  });

  it("passes a genuine connection failure through unchanged", async () => {
    const boom = new Error("GATT operation failed");
    const spy = vi.spyOn(BleClient, "connect").mockRejectedValueOnce(boom);
    await expect(
      tindeqDriver.connect({
        onSamples: () => {},
        onLowBattery: () => {},
        onDisconnected: () => {},
      }),
    ).rejects.toBe(boom);
    spy.mockRestore();
  });

  it("classifies a native 'cancelled' message as cancellation too, not just the DOMException", async () => {
    const spy = vi
      .spyOn(BleClient, "requestDevice")
      .mockRejectedValueOnce(new Error("requestDevice cancelled by user"));
    await expect(
      tindeqDriver.connect({
        onSamples: () => {},
        onLowBattery: () => {},
        onDisconnected: () => {},
      }),
    ).rejects.toBeInstanceOf(DynamometerCancelledError);
    spy.mockRestore();
  });
});
