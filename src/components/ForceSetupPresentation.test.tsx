import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import ForcePathDiagram from "./ForcePathDiagram";
import ForceSetupSummary from "./ForceSetupSummary";

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

  it("renders an editable compact confirmation with mode, equipment, side, and target", () => {
    const html = renderToStaticMarkup(
      <ForceSetupSummary
        setup={{
          mode: "movement",
          exercise: "Half crimp",
          side: "left",
          equipment: "Blue spring",
          preload: "1 kg",
          attachment: "Wall anchor",
          position: "Seat mark 2",
        }}
        confirmed
        targetKg={12}
        locked={false}
        compact
        onMode={() => {}}
        onOpenGuide={() => {}}
      />,
    );
    expect(html).toContain("Movement set");
    expect(html).toContain("Blue spring");
    expect(html).toContain("Left");
    expect(html).toContain("12.0 kg target");
    expect(html).toContain("Setup checked · View guide");
  });
});
