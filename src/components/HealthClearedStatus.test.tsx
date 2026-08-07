import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import HealthClearedStatus from "./HealthClearedStatus";

/// #487 (F4) / review findings 2 & 6: pins the ONE user-visible decision that
/// makes or breaks this fix — after a hard, irreversible delete
/// (deleteHealthMetrics), does the app tell the truth about whether the
/// rebuild actually happened? Before this fix, `resyncHealthHistory` always
/// reported success and this branch didn't exist; a later refactor that
/// silently drops the `ok` read (e.g. `await resyncHealthHistory()` without
/// destructuring) would bring back the always-green banner with
/// `healthSync.test.ts` still fully green, since that file only pins the
/// return value, never what the UI does with it. This is the missing half.

function text(html: string): string {
  return html
    .replace(/<[^>]*>/g, " ")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
}

describe("HealthClearedStatus (#487, F4)", () => {
  it("never claims resyncing when the resync failed", () => {
    const html = renderToStaticMarkup(<HealthClearedStatus resyncFailed={true} native={true} />);
    const t = text(html);
    expect(t).not.toContain("resyncing");
    expect(t).not.toMatch(/will re-sync fresh metrics/);
  });

  it("tells the user the failure is real and names a true remedy", () => {
    const html = renderToStaticMarkup(<HealthClearedStatus resyncFailed={true} native={true} />);
    const t = text(html);
    expect(t).toContain("the resync failed");
    // The remedy must not claim reopening the app rebuilds history — verified
    // false by the reviewer: syncNow only ever writes today's row, and
    // ReadinessWritePolicy can decline even that after noon. The only thing
    // that actually rebuilds history is running Clear & resync again.
    expect(t).not.toMatch(/reopen(ing)? the app.*rebuild/i);
    expect(t).toContain("run Clear & resync again");
  });

  it("shows the device-resync success message on native when the resync actually succeeded", () => {
    const html = renderToStaticMarkup(<HealthClearedStatus resyncFailed={false} native={true} />);
    const t = text(html);
    expect(t).toContain("Health data cleared");
    expect(t).toContain("re-sync fresh metrics");
    expect(t).not.toContain("failed");
  });
});

/// #494 (N5): `resyncHealthHistory` is a documented no-op on web (health
/// ingestion is iPhone-only), so the native success copy — "Your device
/// will re-sync fresh metrics from Apple Health shortly" — is false there:
/// nothing on a web tab is about to resync anything. #487's own test used to
/// pin that exact string regardless of platform; this suite instead reads
/// the rendered web output and requires it NOT claim an on-device resync.
describe("HealthClearedStatus web copy (#494, N5)", () => {
  it("does not claim the device will re-sync when running on web", () => {
    const html = renderToStaticMarkup(<HealthClearedStatus resyncFailed={false} native={false} />);
    const t = text(html);
    expect(t).not.toMatch(/your device will re-sync/i);
    expect(t).not.toContain("failed");
  });

  it("still tells the truth about the clear itself, and names the iPhone app as the real remedy", () => {
    const html = renderToStaticMarkup(<HealthClearedStatus resyncFailed={false} native={false} />);
    const t = text(html);
    expect(t).toContain("Health data cleared");
    expect(t).toMatch(/iphone app/i);
  });
});
