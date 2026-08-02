import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import ForcePathDiagram from "./ForcePathDiagram";
import ForceSetupSummary from "./ForceSetupSummary";

describe("Force setup presentation", () => {
  it("bundles distinct labelled force-path diagrams for both modes", () => {
    const staticDiagram = renderToStaticMarkup(<ForcePathDiagram mode="static" />);
    const movementDiagram = renderToStaticMarkup(<ForcePathDiagram mode="movement" />);
    expect(staticDiagram).toContain("Static hold force path");
    expect(staticDiagram).toContain("handle or edge");
    expect(staticDiagram).not.toContain("Spring /<tspan");
    expect(movementDiagram).toContain("Movement set force path");
    expect(movementDiagram).toContain("compliant spring");
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
