/// Tindeq Progressor driver — the first (and, until #173's hardware half is
/// unblocked, only) implementation of `DynamometerDriver`.
///
/// Transport is `BleClient`: Web Bluetooth in browsers, native CoreBluetooth
/// inside the Capacitor iOS app, one code path for both. Packet parsing and
/// the command bytes live next door in `./tindeq-protocol.ts`.

import { BleClient } from "@capacitor-community/bluetooth-le";
import { Capacitor } from "@capacitor/core";
import { parseNotification, TINDEQ } from "./tindeq-protocol";
import { DynamometerCancelledError } from "./types";
import type {
  DynamometerAvailability,
  DynamometerConnection,
  DynamometerDriver,
  DynamometerListener,
} from "./types";

export const TINDEQ_DRIVER_ID = "tindeq-progressor";

/// BleClient.initialize() is process-wide and only needs to happen once.
///
/// The one deliberate behaviour difference in #173: this flag used to be an
/// `initializedRef` inside the hook, i.e. per hook INSTANCE. The only way to
/// tell the difference is a sign-out → sign-in → connect cycle (which tears
/// TindeqProvider down and back up), where initialize() now correctly isn't
/// repeated. Module scope is the right home for it — the BLE stack belongs to
/// the process, not to a React tree.
let initialized = false;

function writeCmd(deviceId: string, cmd: number): Promise<void> {
  return BleClient.write(
    deviceId,
    TINDEQ.service,
    TINDEQ.controlChar,
    new DataView(new Uint8Array([cmd]).buffer),
  );
}

/// Cancellation is platform-shaped, not device-shaped: dismissing the Web
/// Bluetooth chooser rejects with a `NotFoundError` DOMException, while the
/// native bridge surfaces a plain Error whose message says "cancel". Both mean
/// "the user didn't pick a device" and neither is worth showing — classify
/// here so the consumer only has to know `DynamometerCancelledError`.
function isCancellation(e: unknown): boolean {
  if (e instanceof DOMException && e.name === "NotFoundError") return true;
  return e instanceof Error && /cancel/i.test(e.message);
}

function connection(deviceId: string): DynamometerConnection {
  return {
    driverId: TINDEQ_DRIVER_ID,
    startMeasuring: () => writeCmd(deviceId, TINDEQ.cmd.startWeight),
    stopMeasuring: () => writeCmd(deviceId, TINDEQ.cmd.stop),
    tare: () => writeCmd(deviceId, TINDEQ.cmd.tare),
    // The Progressor answers a battery sample with a tag-0x02 push when it's
    // low, and with nothing at all when it isn't — so this is fire-and-forget
    // by design, not an unfinished request/response.
    refreshDeviceInfo: () => writeCmd(deviceId, TINDEQ.cmd.sampleBattery),
    disconnect: () => BleClient.disconnect(deviceId),
  };
}

export const tindeqDriver: DynamometerDriver = {
  id: TINDEQ_DRIVER_ID,
  deviceName: "Tindeq Progressor",
  capabilities: {
    tare: true,
    lowBatteryWarning: true,
    deviceInfo: true,
  },

  availability(): DynamometerAvailability {
    // Native always has BLE; web needs Web Bluetooth + a secure context.
    const native = Capacitor.isNativePlatform();
    return {
      supported:
        native || (typeof navigator !== "undefined" && "bluetooth" in navigator),
      secure: native || typeof window === "undefined" || window.isSecureContext,
    };
  },

  async connect(listener: DynamometerListener): Promise<DynamometerConnection> {
    try {
      if (!initialized) {
        await BleClient.initialize();
        initialized = true;
      }
      const device = await BleClient.requestDevice({
        namePrefix: TINDEQ.namePrefix,
        optionalServices: [TINDEQ.service],
      });
      await BleClient.connect(device.deviceId, () => listener.onDisconnected());
      await BleClient.startNotifications(
        device.deviceId,
        TINDEQ.service,
        TINDEQ.notifyChar,
        (dv) => {
          const frame = parseNotification(dv);
          if (frame.kind === "weight") listener.onSamples(frame.samples);
          else if (frame.kind === "lowBattery") listener.onLowBattery();
        },
      );
      return connection(device.deviceId);
    } catch (e) {
      // NB: no rollback on a partial connect (e.g. startNotifications failing
      // after connect succeeded) — same as before #173. Deliberately left
      // as-is: this is a refactor, and changing it would change behaviour on a
      // path no test covers.
      if (isCancellation(e)) throw new DynamometerCancelledError();
      throw e;
    }
  },
};
