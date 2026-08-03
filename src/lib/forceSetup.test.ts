import { describe, expect, it } from "vitest";
import { forceMeasurementMode, forceProtocolMode } from "./forceSetup";

describe("force setup presentation mapping", () => {
  it("maps plain-language guidance onto the runtime protocol seam", () => {
    expect(forceProtocolMode("static")).toBe("hold");
    expect(forceProtocolMode("movement")).toBe("reverse_action");
    expect(forceMeasurementMode("hold")).toBe("static");
    expect(forceMeasurementMode("reverse_action")).toBe("movement");
  });
});
