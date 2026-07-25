import { describe, it, expect } from "vitest";
import { parseNotification } from "./tindeq-protocol";

// Encodes one (float32 LE kg, uint32 LE device-timestamp µs) pair as bytes.
function encodePair(kg: number, us: number): number[] {
  const buf = new ArrayBuffer(8);
  const view = new DataView(buf);
  view.setFloat32(0, kg, true);
  view.setUint32(4, us, true);
  return Array.from(new Uint8Array(buf));
}

// Builds a [tag 0x01][len][payload...] weight-frame DataView. `len` is
// passed separately from the actual payload byte count so tests can exercise
// mismatches (declared length vs. real buffer size).
function weightFrame(len: number, payloadBytes: number[]): DataView {
  return new DataView(new Uint8Array([0x01, len, ...payloadBytes]).buffer);
}

describe("parseNotification", () => {
  it("decodes a well-formed weight frame with multiple samples", () => {
    const pairs = [
      { kg: 12.5, us: 1000 },
      { kg: 30.0, us: 2_000_000 },
    ];
    const payload = pairs.flatMap((p) => encodePair(p.kg, p.us));
    const dv = weightFrame(payload.length, payload);

    expect(parseNotification(dv)).toEqual({ kind: "weight", samples: pairs });
  });

  it("clamps when the declared len exceeds the actual buffer", () => {
    const payload = encodePair(5.5, 42); // 8 bytes = 1 real pair
    const dv = weightFrame(100, payload); // len claims 100 bytes of payload

    expect(parseNotification(dv)).toEqual({
      kind: "weight",
      samples: [{ kg: 5.5, us: 42 }],
    });
  });

  it("drops a truncated/partial trailing pair without throwing", () => {
    const payload = [...encodePair(7.25, 999), 0, 0, 0, 0]; // 1 full pair + 4 leftover bytes
    const dv = weightFrame(payload.length, payload);

    expect(parseNotification(dv)).toEqual({
      kind: "weight",
      samples: [{ kg: 7.25, us: 999 }],
    });
  });

  it("returns a zero-sample weight frame when len is 0", () => {
    const dv = weightFrame(0, []);
    expect(parseNotification(dv)).toEqual({ kind: "weight", samples: [] });
  });

  it("returns unknown tag -1 for buffers under 2 bytes", () => {
    expect(parseNotification(new DataView(new ArrayBuffer(0)))).toEqual({
      kind: "unknown",
      tag: -1,
    });
    expect(parseNotification(new DataView(new ArrayBuffer(1)))).toEqual({
      kind: "unknown",
      tag: -1,
    });
  });

  it("decodes tag 0x00 as a response with payload offset at byte 2", () => {
    // Sub-view of a larger buffer with a nonzero byteOffset, to prove the
    // `dv.byteOffset + 2` arithmetic is correct rather than assuming 0.
    const outer = new DataView(new ArrayBuffer(10));
    outer.setUint8(0, 0xff); // unrelated leading bytes
    outer.setUint8(1, 0xee);
    outer.setUint8(2, 0xdd);
    outer.setUint8(3, 0x00); // tag, at the start of the notification sub-view
    outer.setUint8(4, 0x02); // len (unused by the response branch)
    outer.setUint8(5, 0xaa); // payload byte 0
    outer.setUint8(6, 0xbb); // payload byte 1

    const dv = new DataView(outer.buffer, 3); // byteOffset 3, byteLength 7
    const result = parseNotification(dv);

    expect(result.kind).toBe("response");
    if (result.kind !== "response") throw new Error("unreachable");
    expect(result.payload.byteOffset).toBe(5);
    expect(result.payload.getUint8(0)).toBe(0xaa);
    expect(result.payload.getUint8(1)).toBe(0xbb);
  });

  it("decodes tag 0x02 as lowBattery", () => {
    const dv = new DataView(new Uint8Array([0x02, 0x00]).buffer);
    expect(parseNotification(dv)).toEqual({ kind: "lowBattery" });
  });

  it("echoes an unrecognized tag back as unknown", () => {
    const dv = new DataView(new Uint8Array([0x7f, 0x05, 1, 2, 3, 4, 5]).buffer);
    expect(parseNotification(dv)).toEqual({ kind: "unknown", tag: 0x7f });
  });
});
