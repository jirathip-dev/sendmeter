import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import ProtocolBadge from "./ProtocolBadge";

describe("ProtocolBadge", () => {
  it("gives Static a distinct theme color", () => {
    const html = renderToStaticMarkup(<ProtocolBadge mode="hold" />);

    expect(html).toContain("STATIC");
    expect(html).toContain("var(--success)");
  });

  it("keeps resisted movement visually distinct without exposing the internal name", () => {
    const html = renderToStaticMarkup(<ProtocolBadge mode="reverse_action" />);

    expect(html).toContain("MOVEMENT");
    expect(html).not.toContain("REVERSE ACTION");
    expect(html).toContain("var(--primary)");
  });
});
