import { describe, expect, it } from "vitest";
import {
  canSwitchProtocolModality,
  loadProtocolModality,
  presetModality,
  protocolModeFor,
  saveProtocolModality,
} from "./protocolModeContext";

describe("protocol mode context", () => {
  it("treats legacy presets without a mode as static", () => {
    expect(presetModality({ protocolMode: undefined })).toBe("static");
  });

  it("maps the global context to the saved preset mode", () => {
    expect(protocolModeFor("static")).toBe("hold");
    expect(protocolModeFor("reverse_action")).toBe("reverse_action");
  });

  it("allows a real mode change only outside an active run", () => {
    expect(canSwitchProtocolModality("static", "reverse_action", false)).toBe(true);
    expect(canSwitchProtocolModality("static", "reverse_action", true)).toBe(false);
    expect(canSwitchProtocolModality("static", "static", false)).toBe(false);
  });

  it("defaults missing, invalid, or unreadable storage to Static", () => {
    expect(loadProtocolModality({ getItem: () => null, setItem: () => undefined })).toBe("static");
    expect(loadProtocolModality({ getItem: () => "other", setItem: () => undefined })).toBe("static");
    expect(loadProtocolModality({ getItem: () => { throw new Error("blocked"); }, setItem: () => undefined })).toBe("static");
  });

  it("loads Reverse Action and tolerates a failed save", () => {
    expect(loadProtocolModality({ getItem: () => "reverse_action", setItem: () => undefined })).toBe("reverse_action");
    expect(() => saveProtocolModality("static", {
      getItem: () => null,
      setItem: () => { throw new Error("blocked"); },
    })).not.toThrow();
  });
});
