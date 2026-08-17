import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// #612 review F8: whole-repo `npm run lint` must stay green even after a
/// local `swift build`/`swift test` has produced SwiftPM `.build` output
/// inside `native-plugins/*/`. Those directories are gitignored (so they are
/// invisible to CI, which checks out fresh) but present on a dev machine,
/// and eslint lints any `.js` it can see unless the config ignores them —
/// the vendored Capacitor `native-bridge.js` artifacts fail lint with
/// ~68 errors. This pins the ignore so a future removal is loud (the same
/// config-source invariant-test convention as `premiumVisualInvariants.test.ts`).

const REPO = join(import.meta.dirname, "..", "..");
const eslintConfig = readFileSync(join(REPO, "eslint.config.js"), "utf8");

describe("eslint global ignores (#612 review F8)", () => {
  it("ignores **/.build so local SwiftPM builds cannot fail whole-repo lint", () => {
    // Assert against the DECLARATION's array literal, never incidental text:
    // the explanatory comment above `globalIgnores` mentions `.build`, so a
    // `toContain("**/.build")` over the whole file could be satisfied by the
    // comment alone — the standing rule from nativeAuthInvariants.test.ts
    // (incidental text may TRIP a check, but must never SATISFY one) (review
    // N5). The regex captures only what sits inside the globalIgnores call.
    const ignoreList =
      eslintConfig.match(/globalIgnores\(\[([\s\S]*?)\]\)/)?.[1] ?? "";
    expect(ignoreList).toContain("'**/.build'");
    // And pin the whole tuple so removing or reordering any ignore is a loud
    // change (a fifth ignore trips this deliberately).
    expect(eslintConfig).toMatch(
      /globalIgnores\(\[\s*'dist',\s*'ios',\s*'\.claude',\s*'\*\*\/\.build',\s*'mcp\/dist'\s*\]\)/,
    );
  });
});
