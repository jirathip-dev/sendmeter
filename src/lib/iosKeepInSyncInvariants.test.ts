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

/// Collapses a `struct`/`enum` header that wraps across lines (the
/// conformance list overflowing e.g. `struct Foo:\n  Bar, Baz {`) onto one
/// logical line, so `DECL_RE` below — which only recognizes a header ending
/// in `{` on the same physical line — still sees it. Only the header itself
/// (from the `struct`/`enum` keyword up to its first `{`) is touched;
/// everything else in the file, including any body content after that `{`,
/// is untouched. Safe to run on an already-single-line header too: it just
/// collapses internal runs of whitespace, which single-line headers don't
/// have.
function joinWrappedDeclarations(text: string): string {
  return text.replace(
    /\b(?:struct|enum)\s+\S+\s*:[^{]*\{/g,
    (declaration) => declaration.replace(/\s+/g, " "),
  );
}

/// Strips `/* … */` blocks and `//`-to-end-of-line comments, then drops
/// every Swift access modifier (`public`, `private`, `internal`,
/// `fileprivate`, `open`) — the plugin copy is `public` throughout (it's
/// consumed across a module boundary), and per #288's acceptance criteria
/// access-level differences are allowed to differ between the two copies,
/// so none of these may survive into the signature. (Stripping only
/// `public` left a `private`/`internal`/`fileprivate` property in just one
/// copy silently dropped from that copy's signature instead — `PROPERTY_RE`
/// requires the line to *start* with `var`/`let`, so a surviving modifier
/// made it not match at all rather than matching-with-the-modifier.)
/// Finally joins wrapped struct/enum headers (see `joinWrappedDeclarations`)
/// so multi-line declarations aren't silently dropped either.
function normalize(raw: string): string {
  const withoutComments = raw
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
  const withoutModifiers = withoutComments.replace(
    /\b(?:public|private|internal|fileprivate|open)\s+/g,
    "",
  );
  return joinWrappedDeclarations(withoutModifiers);
}

/// Matches both `struct Foo: Bar {` and `enum Foo: String, Codable {` — a
/// nested enum (e.g. a `Phase` property's backing type) is exactly as
/// relevant to the Codable wire shape as a struct: its raw type/conformance
/// list changing (`String` vs `Int`) changes the encoded JSON even though
/// every property line that merely *references* the enum by name looks
/// identical in both copies.
const DECL_RE = /^(struct|enum)\s+(\S+)\s*:\s*(.+?)\s*\{$/;
const ENUM_CASE_RE = /^case\s+(.+)$/;
/// Swift attributes may prefix a stored property, with or without arguments.
/// They don't affect its Codable field name/type and therefore aren't emitted
/// into the signature, but they must not prevent the property from matching.
const PROPERTY_RE =
  /^(?:@[\w.]+(?:\([^)]*\))?\s+)*(var|let)\s+(\S+?)\s*:\s*(.+)$/;
const TYPEALIAS_RE = /^typealias\b/;

/// Typealiases make two textually identical property declarations resolve to
/// different wire types without that difference appearing in the property
/// signature. Resolving arbitrary Swift aliases is outside this structural
/// guard's deliberately small parser, so reject aliases explicitly instead.
function assertNoTypealiases(normalized: string): void {
  const typealias = normalized
    .split("\n")
    .map((line) => line.trim())
    .find((line) => TYPEALIAS_RE.test(line));
  if (typealias) {
    throw new Error(
      `ActivityModels.swift must not use typealias declarations: ${typealias}`,
    );
  }
}

/// Extracts, in file order, just the parts of a Codable shape that
/// ActivityKit's decode actually cares about: struct/enum names + their
/// conformance (or raw-type) lists, enum case names/raw values, and each
/// *stored* property's keyword/name/type. Deliberately does NOT collect
/// `init` declarations or their bodies — the plugin copy's explicit
/// memberwise inits are exactly the allowed difference this signature has
/// to be blind to.
function shapeSignature(raw: string): string[] {
  const normalized = normalize(raw);
  assertNoTypealiases(normalized);

  const signature: string[] = [];
  let braceDepth = 0;
  const enumBodyDepths: number[] = [];

  for (const rawLine of normalized.split("\n")) {
    const line = rawLine.trim();
    if (line === "") continue;

    const declMatch = DECL_RE.exec(line);
    if (declMatch) {
      const [, kind, name, conformances] = declMatch;
      const normalizedConformances = conformances!
        .split(",")
        .map((c) => c.trim())
        .join(", ");
      signature.push(`${kind} ${name}: ${normalizedConformances}`);
      if (kind === "enum") enumBodyDepths.push(braceDepth + 1);
    } else if (enumBodyDepths.includes(braceDepth)) {
      const caseMatch = ENUM_CASE_RE.exec(line);
      if (caseMatch) signature.push(`case ${caseMatch[1]!.trim()}`);
    } else {
      const propertyMatch = PROPERTY_RE.exec(line);
      if (propertyMatch) {
        const [, keyword, name, type] = propertyMatch;
        // A stored property's initializer is not part of its Codable wire
        // shape. Strip it before checking for a computed-property body so a
        // closure-valued default does not make a stored property disappear.
        const wireType = type!.replace(/\s*=.*$/, "").trim();
        // A computed property's declaration line (or its opening line, for a
        // multi-line body) has a `{` somewhere in what PROPERTY_RE captured as
        // the "type" — `var isRecent: Bool { … }` or `var isRecent: Bool {`.
        // Computed properties don't exist on the wire at all, so their
        // implementation must never make this signature diverge; the rest of
        // a multi-line computed body's lines are plain statements that don't
        // match DECL_RE or PROPERTY_RE either, so they're already skipped
        // without any extra state tracking.
        if (!wireType.includes("{")) {
          signature.push(`${keyword} ${name}: ${wireType}`);
        }
      }
    }

    braceDepth += (line.match(/\{/g) ?? []).length;
    braceDepth -= (line.match(/\}/g) ?? []).length;
    while (enumBodyDepths.at(-1)! > braceDepth) enumBodyDepths.pop();
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

describe("shapeSignature() hardening against regex blind spots (#288 revision)", () => {
  it("still catches a conformance-list mismatch when the struct header wraps across lines", () => {
    const singleLine = `
      struct Foo: ActivityAttributes {
        var startedAt: Date
      }
    `;
    const wrappedSame = `
      struct Foo:
        ActivityAttributes
      {
        var startedAt: Date
      }
    `;
    const wrappedDifferent = `
      struct Foo:
        ActivityAttributes, Identifiable
      {
        var startedAt: Date
      }
    `;

    // Wrapping the header doesn't change the shape — same signature either way.
    expect(shapeSignature(wrappedSame)).toEqual(shapeSignature(singleLine));
    // A genuinely different conformance list must still be caught even though
    // the header is wrapped across lines in both copies.
    expect(shapeSignature(wrappedDifferent)).not.toEqual(shapeSignature(wrappedSame));
  });

  it("catches a nested enum's raw-type divergence even though the referencing property line is identical", () => {
    const withStringRawType = `
      enum Phase: String, Codable {
        case climbing, resting
      }
      struct S: Codable {
        var phase: Phase
      }
    `;
    const withIntRawType = `
      enum Phase: Int, Codable {
        case climbing, resting
      }
      struct S: Codable {
        var phase: Phase
      }
    `;

    // Both `var phase: Phase` lines read identically — only the enum's own
    // raw type differs, which is exactly the real Codable-encoding
    // divergence ("climbing" vs 0 on the wire) this must not miss.
    expect(shapeSignature(withStringRawType)).not.toEqual(shapeSignature(withIntRawType));
  });

  it("catches enum case renames and raw-value changes", () => {
    const baseline = `
      enum Phase: String, Codable {
        case climbing
        case resting = "rest"
      }
    `;
    const renamedCase = `
      enum Phase: String, Codable {
        case sending
        case resting = "rest"
      }
    `;
    const changedRawValue = `
      enum Phase: String, Codable {
        case climbing
        case resting = "recovery"
      }
    `;

    expect(shapeSignature(renamedCase)).not.toEqual(shapeSignature(baseline));
    expect(shapeSignature(changedRawValue)).not.toEqual(shapeSignature(baseline));
  });

  it("excludes stored-property default values from the wire-shape type", () => {
    const withoutDefaults = `
      struct S: Codable {
        var count: Int
        let label: String
      }
    `;
    const withDefaults = `
      struct S: Codable {
        var count: Int = 3
        let label: String = "three"
      }
    `;
    const withDifferentDefaults = `
      struct S: Codable {
        var count: Int = 99
        let label: String = "ninety-nine"
      }
    `;

    expect(shapeSignature(withDefaults)).toEqual(shapeSignature(withoutDefaults));
    expect(shapeSignature(withDifferentDefaults)).toEqual(shapeSignature(withoutDefaults));
  });

  it("supports legal whitespace before a property colon without hiding type drift", () => {
    const conventionalSpacing = `
      struct S: Codable {
        var count: Int
      }
    `;
    const spacedColon = `
      struct S: Codable {
        var count : Int
      }
    `;
    const spacedColonWithDifferentType = `
      struct S: Codable {
        var count : String
      }
    `;

    expect(shapeSignature(spacedColon)).toEqual(shapeSignature(conventionalSpacing));
    expect(shapeSignature(spacedColonWithDifferentType)).not.toEqual(
      shapeSignature(conventionalSpacing),
    );
  });

  it("ignores a computed property's implementation — only stored properties affect the shape", () => {
    const impl1 = `
      struct S: Codable {
        var count: Int
        var isRecent: Bool {
          count < 3
        }
      }
    `;
    const impl2 = `
      struct S: Codable {
        var count: Int
        var isRecent: Bool {
          count > 10 && count < 100
        }
      }
    `;
    const singleLineComputed = `
      struct S: Codable {
        var count: Int
        var isRecent: Bool { count < 3 }
      }
    `;

    // Differing computed-property bodies must not make the signature diverge...
    expect(shapeSignature(impl1)).toEqual(shapeSignature(impl2));
    // ...whether the computed property's body is single-line or multi-line.
    expect(shapeSignature(singleLineComputed)).toEqual(shapeSignature(impl1));
  });

  it("treats private/internal/fileprivate the same as public — access-level differences stay allowed", () => {
    const withoutModifier = `
      struct S: Codable {
        var secret: String
        var visible: Int
      }
    `;
    const withPrivate = `
      struct S: Codable {
        private var secret: String
        var visible: Int
      }
    `;
    const withInternal = `
      struct S: Codable {
        internal var secret: String
        fileprivate var visible: Int
      }
    `;

    expect(shapeSignature(withPrivate)).toEqual(shapeSignature(withoutModifier));
    expect(shapeSignature(withInternal)).toEqual(shapeSignature(withoutModifier));
  });

  it("catches stored-property type drift behind leading Swift attributes", () => {
    const withStringProperty = `
      struct S: Codable {
        @MainActor @available(iOS 17, *) var debugTag: String
      }
    `;
    const withIntProperty = `
      struct S: Codable {
        @available(iOS 17, *) public var debugTag: Int
      }
    `;

    expect(shapeSignature(withStringProperty)).toContain("var debugTag: String");
    expect(shapeSignature(withIntProperty)).not.toEqual(
      shapeSignature(withStringProperty),
    );
  });

  it("rejects typealias indirection instead of silently comparing the alias name", () => {
    const withStringAlias = `
      typealias PhaseRaw = String
      struct S: Codable {
        var phase: PhaseRaw
      }
    `;
    const withIntAlias = `
      public typealias PhaseRaw = Int
      struct S: Codable {
        var phase: PhaseRaw
      }
    `;

    expect(() => shapeSignature(withStringAlias)).toThrow(
      /must not use typealias/,
    );
    expect(() => shapeSignature(withIntAlias)).toThrow(/must not use typealias/);
  });
});
