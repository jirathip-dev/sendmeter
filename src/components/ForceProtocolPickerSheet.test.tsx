import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import ForceProtocolPickerSheet, { SelectedProtocolCard } from "./ForceProtocolPickerSheet";
import { MOVEMENT_STARTER_PRESET, protocolSummary } from "../lib/movementProtocol";

describe("Force protocol phone presentation", () => {
  it("keeps the built-in Movement Starter prescription exact", () => {
    expect(MOVEMENT_STARTER_PRESET).toMatchObject({
      name: "Movement Starter",
      protocolMode: "reverse_action",
      setupNote: "Resisted movement",
      cadenceOutS: 3,
      cadenceReturnS: 1,
      reps: 10,
      sets: 3,
      restSetsS: 60,
      capacityEvidence: false,
    });
    expect(protocolSummary(MOVEMENT_STARTER_PRESET)).toBe(
      "3s concentric · 1s eccentric · 10 reps × 3 sets · 60s rest",
    );
  });

  it("makes the selected protocol prominent and exposes one chooser action", () => {
    const html = renderToStaticMarkup(
      <SelectedProtocolCard protocol={MOVEMENT_STARTER_PRESET} locked={false} onChoose={() => {}} onClear={() => {}} />,
    );
    expect(html).toContain("Movement Starter");
    expect(html).toContain("Choose another");
    expect(html).toContain("Use free hold");
    expect(html).toContain("3s concentric · 1s eccentric");
    expect(html).not.toContain("Protocol mode");
  });

  it("explains resisted movement in plain language inside Suggested", () => {
    const html = renderToStaticMarkup(
      <ForceProtocolPickerSheet
        selectedId={null}
        onClose={() => {}}
        onMovementStarter={() => {}}
        suggestedStatic={<div>Static suggestions</div>}
        myProtocols={<div>My saved protocols</div>}
      />,
    );
    expect(html).toContain("Move through your range against resistance");
    expect(html).toContain("the clock guides each rep");
  });

  it("keeps the chooser visible but disabled while a run owns the inputs", () => {
    const html = renderToStaticMarkup(
      <SelectedProtocolCard protocol={MOVEMENT_STARTER_PRESET} locked onChoose={() => {}} onClear={() => {}} />,
    );
    expect(html.match(/disabled/g)).toHaveLength(2);
    expect(html).toContain("Locked while armed or measuring");
  });
});
