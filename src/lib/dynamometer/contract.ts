/// The behavioural contract every `DynamometerDriver` must satisfy (#173).
///
/// This is test-support code that lives in `src/` on purpose: it is the thing
/// a future driver author runs to find out whether their driver is actually
/// finished. Nothing in the app imports it, so it never reaches the bundle.
///
/// A driver is exercised entirely through the interface — the harness is the
/// only device-specific part, and it exists so the same assertions can drive a
/// real driver (with its transport mocked) and a stub driver.

import { describe, expect, it, vi } from "vitest";
import { DynamometerCancelledError } from "./types";
import type { DynamometerDriver, DynamometerListener, ForceSample } from "./types";

/// What a driver's test harness must be able to do: play the part of the
/// device on the far side of the transport.
export interface DriverContractHarness {
  driver: DynamometerDriver;
  /// Push a batch of readings from the device side, as the transport would.
  emitSamples(samples: ForceSample[]): void;
  /// Push a low-battery warning. Only called when the driver claims the
  /// capability.
  emitLowBattery(): void;
  /// Simulate an unsolicited link drop (out of range, powered off).
  emitDrop(): void;
  /// Commands the driver has issued to the device since connect, in order,
  /// named: "start" | "stop" | "tare" | "deviceInfo" | "disconnect".
  commands(): string[];
  /// Make the next `connect()` behave as if the user dismissed the picker.
  simulateCancel(): void;
}

function spyListener(): DynamometerListener & {
  samples: ForceSample[][];
  lowBattery: number;
  disconnects: number;
} {
  const state = {
    samples: [] as ForceSample[][],
    lowBattery: 0,
    disconnects: 0,
    onSamples(s: ForceSample[]) {
      state.samples.push(s);
    },
    onLowBattery() {
      state.lowBattery += 1;
    },
    onDisconnected() {
      state.disconnects += 1;
    },
  };
  return state;
}

export function runDriverContract(
  label: string,
  makeHarness: () => DriverContractHarness,
): void {
  describe(`DynamometerDriver contract: ${label}`, () => {
    it("describes itself with a stable id, a device name and boolean capabilities", () => {
      const { driver } = makeHarness();
      expect(driver.id).toBeTruthy();
      expect(driver.deviceName).toBeTruthy();
      expect(typeof driver.capabilities.tare).toBe("boolean");
      expect(typeof driver.capabilities.lowBatteryWarning).toBe("boolean");
      expect(typeof driver.capabilities.deviceInfo).toBe("boolean");
    });

    it("reports availability synchronously as two booleans", () => {
      const { driver } = makeHarness();
      const a = driver.availability();
      expect(typeof a.supported).toBe("boolean");
      expect(typeof a.secure).toBe("boolean");
    });

    it("connects and hands back a connection tagged with its own driver id", async () => {
      const h = makeHarness();
      const conn = await h.driver.connect(spyListener());
      expect(conn.driverId).toBe(h.driver.id);
    });

    it("delivers device readings to onSamples as batches of {us, kg}", async () => {
      const h = makeHarness();
      const listener = spyListener();
      const conn = await h.driver.connect(listener);
      await conn.startMeasuring();

      h.emitSamples([
        { us: 1_000, kg: 12.5 },
        { us: 11_000, kg: 30 },
      ]);

      expect(listener.samples).toEqual([
        [
          { us: 1_000, kg: 12.5 },
          { us: 11_000, kg: 30 },
        ],
      ]);
    });

    it("issues start and stop as distinct commands", async () => {
      const h = makeHarness();
      const conn = await h.driver.connect(spyListener());
      await conn.startMeasuring();
      await conn.stopMeasuring();
      expect(h.commands()).toEqual(["start", "stop"]);
    });

    it("resolves tare — issuing a command only if it claims the capability", async () => {
      const h = makeHarness();
      const conn = await h.driver.connect(spyListener());
      await expect(conn.tare()).resolves.toBeUndefined();
      // A capability a driver LACKS is a resolved no-op, never a throw: the
      // consumer must not have to try/catch to discover what's missing.
      expect(h.commands()).toEqual(h.driver.capabilities.tare ? ["tare"] : []);
    });

    it("resolves refreshDeviceInfo — issuing a command only if it claims the capability", async () => {
      const h = makeHarness();
      const conn = await h.driver.connect(spyListener());
      await expect(conn.refreshDeviceInfo()).resolves.toBeUndefined();
      expect(h.commands()).toEqual(
        h.driver.capabilities.deviceInfo ? ["deviceInfo"] : [],
      );
    });

    it("fires onLowBattery only when it claims the capability", async () => {
      const h = makeHarness();
      const listener = spyListener();
      await h.driver.connect(listener);
      if (h.driver.capabilities.lowBatteryWarning) {
        h.emitLowBattery();
        expect(listener.lowBattery).toBe(1);
      } else {
        expect(listener.lowBattery).toBe(0);
      }
    });

    it("reports an unsolicited drop through onDisconnected", async () => {
      const h = makeHarness();
      const listener = spyListener();
      await h.driver.connect(listener);
      h.emitDrop();
      expect(listener.disconnects).toBe(1);
    });

    it("does NOT fire onDisconnected for a consumer-initiated disconnect", async () => {
      const h = makeHarness();
      const listener = spyListener();
      const conn = await h.driver.connect(listener);
      await conn.disconnect();
      expect(listener.disconnects).toBe(0);
      expect(h.commands()).toEqual(["disconnect"]);
    });

    it("rejects a dismissed device picker as DynamometerCancelledError, not a failure", async () => {
      const h = makeHarness();
      h.simulateCancel();
      await expect(h.driver.connect(spyListener())).rejects.toBeInstanceOf(
        DynamometerCancelledError,
      );
    });

    it("survives a listener whose callbacks are torn off the object", async () => {
      // The hook builds its listener inline; a driver must not depend on
      // `this` binding when it calls back.
      const h = makeHarness();
      const onSamples = vi.fn();
      await h.driver.connect({
        onSamples,
        onLowBattery: () => {},
        onDisconnected: () => {},
      });
      h.emitSamples([{ us: 5, kg: 1 }]);
      expect(onSamples).toHaveBeenCalledWith([{ us: 5, kg: 1 }]);
    });
  });
}
