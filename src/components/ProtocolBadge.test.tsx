import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import ProtocolBadge from "./ProtocolBadge";

describe("ProtocolBadge", () => {
  it("gives Static a distinct theme color", () => {
    const html = renderToStaticMarkup(<ProtocolBadge mode="hold" />);

    expect(html).toContain("STATIC");
    expect(html).toContain("var(--success)");
  });

  it("keeps Reverse Action visually distinct", () => {
    const html = renderToStaticMarkup(<ProtocolBadge mode="reverse_action" />);

    expect(html).toContain("REVERSE ACTION");
    expect(html).toContain("var(--primary)");
  });
});
