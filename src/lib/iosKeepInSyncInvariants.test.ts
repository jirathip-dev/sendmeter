import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard over #288's KEEP-IN-SYNC duplicated Swift file pairs, in
/// the same spirit as `nativeAuthInvariants.test.ts` / `signOutInvariants.test.ts`:
/// a comment asserting a contract is not the contract, and nothing in
/// `ci.yml`'s `quality` job (or the path-filtered `ios-ci.yml`) otherwise
/// notices these two pairs drift apart.
///
/// - `WidgetShared.swift` (watch-app copy + widget-extension copy) is
///   supposed to be **byte-identical** — the App Group serializes by Codable
///   shape, and there is no reason for the two copies to differ at all.
/// - `ActivityModels.swift` (widget copy + `sendlog-live-activity` plugin
///   copy) only needs to be **shape-identical** — ActivityKit matches by
///   unqualified type name + Codable shape, so the plugin copy's `public`
///   modifiers and explicit memberwise inits (needed because the type is
///   consumed across a module boundary) don't matter, only struct names,
///   field names and field types, in order.
///
/// Both tests read the files with plain `readFileSync`, so a moved/renamed
/// file fails the test loudly (ENOENT) rather than silently passing.

const REPO = join(import.meta.dirname, "..", "..");

const WIDGET_SHARED_WATCH = join(
  REPO, "ios", "App", "SendLogWatch Watch App", "Shared", "WidgetShared.swift",
);
const WIDGET_SHARED_WIDGET = join(
  REPO, "ios", "App", "SendLogWatchWidgets", "WidgetShared.swift",
);

const ACTIVITY_MODELS_WIDGET = join(
  REPO, "ios", "App", "SendmeterWidgets", "ActivityModels.swift",
);
const ACTIVITY_MODELS_PLUGIN = join(
  REPO, "native-plugins", "sendlog-live-activity", "ios", "Sources",
  "SendLogLiveActivity", "ActivityModels.swift",
);

/// Strips `/* … */` blocks and `//`-to-end-of-line comments, then drops
/// `public ` tokens — the plugin copy is `public` throughout (it's consumed
/// across a module boundary) and that doesn't affect the Codable shape.
function normalize(raw: string): string {
  return raw
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n")
    .replace(/\bpublic\s+/g, "");
}

const STRUCT_RE = /^struct\s+(\S+)\s*:\s*(.+?)\s*\{$/;
const PROPERTY_RE = /^(var|let)\s+(\S+):\s*(.+)$/;

/// Extracts, in file order, just the parts of a Codable shape that
/// ActivityKit's decode actually cares about: struct names + their
/// conformance lists, and each stored property's keyword/name/type.
/// Deliberately does NOT collect `init` declarations or their bodies — the
/// plugin copy's explicit memberwise inits are exactly the allowed
/// difference this signature has to be blind to.
function shapeSignature(raw: string): string[] {
  const signature: string[] = [];
  for (const rawLine of normalize(raw).split("\n")) {
    const line = rawLine.trim();
    if (line === "") continue;

    const structMatch = STRUCT_RE.exec(line);
    if (structMatch) {
      const [, name, conformances] = structMatch;
      const normalizedConformances = conformances!
        .split(",")
        .map((c) => c.trim())
        .join(", ");
      signature.push(`struct ${name}: ${normalizedConformances}`);
      continue;
    }

    const propertyMatch = PROPERTY_RE.exec(line);
    if (propertyMatch) {
      const [, keyword, name, type] = propertyMatch;
      signature.push(`${keyword} ${name}: ${type!.trim()}`);
    }
  }
  return signature;
}

describe("WidgetShared.swift stays byte-identical across targets (#288)", () => {
  it("the watch-app copy and the widget-extension copy are byte-for-byte equal", () => {
    // The App Group serializes by Codable shape — there's no `public`/init
    // asymmetry here like ActivityModels has, so byte identity is the actual
    // contract, not just a stand-in for it.
    const watchCopy = readFileSync(WIDGET_SHARED_WATCH, "utf8");
    const widgetCopy = readFileSync(WIDGET_SHARED_WIDGET, "utf8");
    expect(widgetCopy).toBe(watchCopy);
  });
});

describe("ActivityModels.swift stays Codable-shape-identical across targets (#288)", () => {
  it("the widget copy and the plugin copy normalize to the same shape signature", () => {
    const widgetShape = shapeSignature(readFileSync(ACTIVITY_MODELS_WIDGET, "utf8"));
    const pluginShape = shapeSignature(readFileSync(ACTIVITY_MODELS_PLUGIN, "utf8"));

    // A signature that came back empty would make the equality below
    // vacuously true — guard against the regex extraction silently matching
    // nothing (e.g. after an unrelated formatting change).
    expect(widgetShape.length).toBeGreaterThan(10);

    expect(pluginShape).toEqual(widgetShape);
  });
});
