import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import ForcePathDiagram from "./ForcePathDiagram";
import ForceSetupGuide from "./ForceSetupGuide";
import ForceConnectionCard from "./ForceConnectionCard";
import { sensorlessLaunchAvailable } from "../lib/forceConnection";

describe("Force setup presentation", () => {
  it("keeps both force-path diagrams equipment-only and explicit about measurement limits", () => {
    const staticDiagram = renderToStaticMarkup(<ForcePathDiagram mode="static" />);
    const movementDiagram = renderToStaticMarkup(<ForcePathDiagram mode="movement" />);
    expect(staticDiagram).toContain("Static hold force path");
    expect(staticDiagram).toContain("contact point");
    expect(staticDiagram).toContain("All user-defined setup references");
    expect(staticDiagram).not.toContain("Spring /<tspan");
    expect(movementDiagram).toContain("Movement set force path");
    expect(movementDiagram).toContain("compliant element");
    expect(movementDiagram).toContain("user-defined moving reference");
    expect(movementDiagram).toContain("not form, joint position, or exercise safety");
    expect(movementDiagram).not.toMatch(/rotator cuff|hip rotator|block pull/i);
    expect(movementDiagram).toContain('role="img"');
  });

  it("renders movement setup as information without checks or saved approval", () => {
    const html = renderToStaticMarkup(<ForceSetupGuide mode="movement" sensor onClose={() => {}} />);
    expect(html).toContain("Movement set");
    expect(html).toContain("Movement set force path");
    expect(html).toContain("Equipment principles");
    expect(html).toContain("Make the setup repeatable");
    expect(html).not.toMatch(/equipment checked|not checked|save equipment check|live readiness check/i);
    expect(html).not.toContain('type="checkbox"');
  });

  it("links to optional guidance from the connected Progressor card", () => {
    const html = renderToStaticMarkup(
      <ForceConnectionCard
        status="connected"
        locked={false}
        onOpenGauge={() => {}}
        onOpenSetup={() => {}}
      />,
    );
    expect(html).toContain("Progressor");
    expect(html).toContain("Open gauge");
    expect(html).toContain("How to set up");
    expect(html).not.toMatch(/equipment checked|not checked/i);
    expect(html).not.toContain("Train without sensor");
  });

  it("explains cadence-only limits without presenting sensor controls", () => {
    const html = renderToStaticMarkup(<ForceSetupGuide mode="movement" sensor={false} onClose={() => {}} />);
    expect(html).toContain("Cadence only");
    expect(html).toContain("no force sensor, target band, tare, or movement detection");
    expect(html).not.toContain("Movement set force path");
    expect(html).not.toMatch(/connect progressor|start live readiness|save equipment/i);
  });

  it("only offers sensorless launch before a device session exists", () => {
    expect(sensorlessLaunchAvailable("idle")).toBe(true);
    expect(sensorlessLaunchAvailable("unsupported")).toBe(true);
    for (const status of ["connecting", "connected", "armed", "measuring"] as const) {
      expect(sensorlessLaunchAvailable(status)).toBe(false);
    }
  });
});
