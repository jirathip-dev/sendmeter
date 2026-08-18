import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard over #656's AC5: every haptic must route through
/// `Sources/App/Haptics.swift` — no `UIImpactFeedbackGenerator`,
/// `UINotificationFeedbackGenerator`, `UISelectionFeedbackGenerator` or
/// `CHHapticEngine` in feature code. Same spirit and shape as
/// `nativeAuthInvariants.test.ts` / `signOutInvariants.test.ts`: a rule
/// nothing checks is a comment, and the `quality` job never compiles the
/// Swift, so a stray generator in a SwiftUI view would otherwise merge with an
/// all-green PR.
///
/// Deliberately a raw-text scan over comment-and-string-stripped code: the
/// generator type names are the thing being banned, so a mention inside a
/// comment or string must not satisfy or evade the check. The allow-list is
/// exactly the one dispatcher file; a second file allowed to hold a generator
/// must be added here in the same change that adds it.
const REPO = join(import.meta.dirname, "..", "..");

const NATIVE_SOURCES = join(REPO, "native", "SendmeterNative", "Sources");
// The one file allowed to hold the UIKit feedback generators.
const HAPTICS_DISPATCHER = join(NATIVE_SOURCES, "App", "Haptics.swift");

const GENERATOR_TYPES = [
  "UIImpactFeedbackGenerator",
  "UINotificationFeedbackGenerator",
  "UISelectionFeedbackGenerator",
  "CHHapticEngine",
];

const SKIP_DIR_NAMES = new Set([".build", ".swiftpm", "DerivedData", "Packages", "Pods"]);

function swiftFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    if (entry.startsWith(".") || SKIP_DIR_NAMES.has(entry)) return [];
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return swiftFiles(path);
    return path.endsWith(".swift") ? [path] : [];
  });
}

/// Strips `//` comments and `/* … */` blocks — these files necessarily
/// *discuss* the generators in doc comments, and the point is which code
/// touches one.
function code(path: string): string {
  return readFileSync(path, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

describe("#656 haptics invariants", () => {
  it("finds the source tree it is scanning", () => {
    // A scan that silently matched nothing would pass every assertion below.
    const files = swiftFiles(NATIVE_SOURCES);
    expect(files.length).toBeGreaterThan(30);
    expect(files.map((f) => f.slice(REPO.length + 1))).toContain(
      "native/SendmeterNative/Sources/App/Haptics.swift",
    );
  });

  it("the dispatcher file exists and is the only generator holder", () => {
    // readFileSync throws ENOENT loudly if the dispatcher is moved/renamed.
    const dispatcher = readFileSync(HAPTICS_DISPATCHER, "utf8");
    expect(dispatcher).toMatch(/UIImpactFeedbackGenerator/);
    expect(dispatcher).toMatch(/UISelectionFeedbackGenerator/);
    expect(dispatcher).toMatch(/UINotificationFeedbackGenerator/);
  });

  for (const type of GENERATOR_TYPES) {
    it(`never uses ${type} outside the dispatcher`, () => {
      const offenders = swiftFiles(NATIVE_SOURCES)
        .filter((path) => path !== HAPTICS_DISPATCHER)
        .flatMap((path) => {
          const text = code(path);
          if (!text.includes(type)) return [];
          const line = text.split("\n").findIndex((l) => l.includes(type)) + 1;
          return [`${path.slice(REPO.length + 1)}:${line}`];
        });
      expect(offenders).toEqual([]);
    });
  }
});
