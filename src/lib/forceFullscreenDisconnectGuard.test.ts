import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard for #486 finding 2: ForceFullscreen's Disconnect pill was
/// live and unconditional through `measuring || armed || counting` — exactly
/// the states where Tare and "How to set up" are hidden for being unsafe —
/// so one mistimed tap during a max-effort rep silently discarded it, with
/// no confirmation and no salvage (`disconnect()` in useTindeq.ts is the
/// deliberate user path, not the unexpected-drop path that salvages).
///
/// ForceFullscreen can't be rendered in this repo's test environment (no
/// jsdom/testing-library, and it unconditionally `createPortal`s to
/// `document.body` — see forcePrepare.test.ts's header comment for the same
/// situation with the free-hold countdown). So — same move as that file and
/// as `curveCandidateInvariants.test.ts` for the curve-poisoning finding —
/// the actual decision (`disconnectNeedsConfirm`) is unit-tested directly in
/// forcePrepare.test.ts, and this file is the crude text-scan pinning that
/// ForceFullscreen's Disconnect button is actually WIRED to it, so reverting
/// the JSX back to a bare `onClick={tindeq.disconnect}` — which still passes
/// every behavioural test on the pure function — fails here instead of
/// shipping green.

const FORCE_FULLSCREEN = join(
  import.meta.dirname,
  "..",
  "components",
  "ForceFullscreen.tsx",
);

describe("ForceFullscreen's Disconnect pill is gated by disconnectNeedsConfirm (#486)", () => {
  const src = readFileSync(FORCE_FULLSCREEN, "utf8");

  it("imports disconnectNeedsConfirm from the shared lib", () => {
    expect(src).toMatch(
      /import\s*\{[^}]*\bdisconnectNeedsConfirm\b[^}]*\}\s*from\s*["']\.\.\/lib\/forcePrepare["']/,
    );
  });

  it("does not reintroduce a bare unconditional disconnect on tap", () => {
    expect(src).not.toMatch(/onClick=\{tindeq\.disconnect\}/);
  });

  it("evaluates the guard with the same three flags Tare/setup-guide already hide behind", () => {
    expect(src).toMatch(
      /disconnectNeedsConfirm\(\s*\{\s*measuring,\s*armed,\s*counting\s*\}\s*\)/,
    );
  });

  it("renders a confirm dialog for the guarded path rather than silently no-op'ing", () => {
    expect(src).toMatch(/confirmDisconnect/);
    expect(src).toMatch(/<ConfirmDialog/);
  });
});
