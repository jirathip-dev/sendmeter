// Tindeq Progressor BLE protocol. Pure parsing — no BLE objects here.
//
// The wire-format half of the Tindeq driver (#173): `./tindeq.ts` owns the
// transport and implements the device-agnostic `DynamometerDriver`, this file
// owns the bytes. The split is deliberate — it keeps this module free of
// Capacitor/BLE imports (so its tests stay pure, and it stays a 1:1 mirror of
// SendLogWatchCore's `TindeqProtocol.swift`, which the watch app parses with).

export const TINDEQ = {
  namePrefix: "Progressor",
  service: "7e4e1701-1ea6-40c9-9dcc-13d34ffead57",
  notifyChar: "7e4e1702-1ea6-40c9-9dcc-13d34ffead57",
  controlChar: "7e4e1703-1ea6-40c9-9dcc-13d34ffead57",
  cmd: {
    tare: 0x64,
    startWeight: 0x65,
    stop: 0x66,
    sampleBattery: 0x6f,
  },
} as const;

export type TindeqFrame =
  | { kind: "weight"; samples: { us: number; kg: number }[] }
  | { kind: "response"; payload: DataView }
  | { kind: "lowBattery" }
  | { kind: "unknown"; tag: number };

// Frames are [tag u8][length u8][payload]. Weight payload (tag 0x01) is
// repeated pairs of (float32 LE kg, uint32 LE device-timestamp µs).
export function parseNotification(dv: DataView): TindeqFrame {
  if (dv.byteLength < 2) return { kind: "unknown", tag: -1 };
  const tag = dv.getUint8(0);
  const len = dv.getUint8(1);

  if (tag === 0x01) {
    const samples: { us: number; kg: number }[] = [];
    const pairs = Math.floor(Math.min(len, dv.byteLength - 2) / 8);
    for (let i = 0; i < pairs; i++) {
      const offset = 2 + i * 8;
      samples.push({
        kg: dv.getFloat32(offset, true),
        us: dv.getUint32(offset + 4, true),
      });
    }
    return { kind: "weight", samples };
  }
  if (tag === 0x00) {
    // Bound explicitly to `dv`'s own remaining length. Without the third
    // argument, `DataView`'s constructor defaults to the END OF THE
    // UNDERLYING BUFFER, not the end of `dv` itself — on a `dv` that is a
    // sub-view not reaching its buffer's end (a shared/reused ArrayBuffer),
    // that silently leaks whatever bytes follow into the response payload.
    // Mirrors SendLogWatchCore's TindeqProtocol.swift, where
    // `data.dropFirst(2)` is always bounded to `data`'s own endIndex.
    return {
      kind: "response",
      payload: new DataView(dv.buffer, dv.byteOffset + 2, dv.byteLength - 2),
    };
  }
  if (tag === 0x02) return { kind: "lowBattery" };
  return { kind: "unknown", tag };
}
