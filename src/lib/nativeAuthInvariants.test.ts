import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard over code CI cannot otherwise check (issues #196, #265,
/// #488, #502).
///
/// Two facts make this file worth its oddness — a TypeScript test reading
/// Swift:
///
/// 1. **The Swift never compiles in the `quality` job.** Only `ios-ci.yml`'s
///    macOS `swift` job builds the watch and phone targets, and it is
///    path-filtered and frequently queued. A refresh token could be
///    reintroduced on the native side and merge with an all-green PR.
/// 2. **#196 failed exactly here.** Its rule — "no native client may reach a
///    refreshing accessor" — was correct, comprehensively documented, verified
///    by inspection, and still regressed into a production session revocation
///    (#265). A rule nothing checks is a comment.
///
/// **How the invariant is enforced since #502: the compiler first, this file
/// second.** Before #502 this file tried to make the accessor *detectable* by
/// text scan, and lost three consecutive review rounds (#488): round 0's
/// fixed substrings fell to a one-hop alias; round 1's bare-`.auth` ban fell
/// to a comment stripper that deleted string contents (an ordinary URL-bearing
/// log line hid a real accessor); round 2's hand-rolled tokenizer fixed that
/// and created four new defects, two of them regressions; round 3 fixed those
/// and still shipped with three known residual holes (raw-string `\#(…)`
/// interpolation, bare regex literals each holding one quote, a
/// dot/identifier split across a newline). Hand-rolled lexing of Swift to
/// keep an accessor detectable is a losing arms race, and its failure mode is
/// silent.
///
/// #502 ends the race by making the accessor *unreachable by construction*:
/// each native target has a façade — `SupabaseService` on the watch,
/// `HealthConfig` in the health plugin — holding its `SupabaseClient` in a
/// `private` property and exposing exactly one member,
/// `from(_:) -> PostgrestQueryBuilder`, a type with no member path back to
/// the client or to `.auth`. Outside those two files, a refreshing accessor
/// — named, aliased, optional-chained, written inside a raw-string
/// interpolation, or split across newlines — is not something a scan must
/// find; it is a compile error. All three of round 3's residual holes were
/// re-verified as compile errors under the façade (see the #502 mutation
/// probes in that PR).
///
/// The compiler's guarantee rests on three premises, each pinned below by an
/// assertion small enough to read whole and (for the first two) run on RAW
/// file text — no lexer, so nothing to silently desync; the worst failure is
/// a LOUD false positive on a comment, fixed by rewording the comment, never
/// by weakening the pin:
///
/// 1. **The client properties really are `private`** — and every
///    `SupabaseClient`-typed declaration inside a façade sits on a `private`
///    line, so the façade cannot quietly grow a `static let leaked:
///    SupabaseClient` for outside code to dot off.
/// 2. **There is no other client to reach.** The identifier `SupabaseClient`
///    appears nowhere in either guarded directory outside the two façade
///    files (raw text, so a construction hidden inside a string, comment
///    trick, or regex literal is still seen), and `AuthClient` /
///    `GoTrueClient` — directly constructible, and a self-built one has no
///    `.auth` member access for any scan to see — appear in no *code*
///    anywhere in either directory (code-only view, because comments
///    legitimately discuss `AuthClient`).
/// 3. **The SDK is importable only inside the guarded directories** — the
///    #488 allow-list over all six separately-importable supabase-swift
///    products (`Supabase`, `Auth`, `PostgREST`, `Realtime`, `Storage`,
///    `Functions`), kept unchanged below.
///
/// The pre-#502 accessor scans (ROTATING_CALLS / the `.auth` member-access
/// scan, tokenizer-based) are KEPT as tripwires, no longer as the line of
/// defence. They are the only automated check on the two façade files
/// themselves — the compiler cannot police code that legitimately holds the
/// client — and post-#502 there is no legitimate `.auth` member access
/// anywhere in either directory, so any future match is dead code or an
/// attack, never a false positive to engineer around.
///
/// **What this arrangement does NOT cover, stated precisely (three earlier
/// versions of this docstring overclaimed; this list is the contract):**
///
/// - **The two façade files are trusted code.** Inside them the compiler
///   enforces nothing about `.auth`, and the tokenized tripwires retain the
///   round-3 residuals: `\#(…)` raw-string interpolation is blanked as
///   opaque string content; a Swift bare regex literal containing a quote
///   character can desync string detection (regex literals are not
///   tokenized); `client.\n    auth` split across a newline contains no
///   `.auth` substring. A hostile or careless edit *within the façades*
///   could therefore hide an accessor from every assertion here. The guard
///   is review of façade diffs — which is why the façades stay small and
///   single-purpose.
/// - **Type laundering that never names a banned identifier in scannable
///   code** — e.g. a typealias for `SupabaseClient` itself hidden inside
///   tokenizer-evading text, then used to construct a fresh client. The
///   raw-text identifier grep (premise 2) sees strings, comments and regex
///   literals alike, so the alias *target* must be written in a shape no
///   formatter produces to get past it — but "must be written weirdly" is
///   an obstacle, not an impossibility. Review's job.
/// - **Hand-rolled HTTP.** A `URLSession` POST to `/auth/v1/token` with the
///   committed anon key involves no SDK type; neither the compiler barrier
///   nor anything in this file sees it. The operative backstop is #265's,
///   not this file's: there is no refresh token on the device or the wire to
///   spend, so a hand-rolled call would need credentials the native side
///   does not hold.
/// - **A rotating accessor added to the SDK under a name with no "auth" in
///   it.** A grep cannot know a name it has never seen; same answer as the
///   precedent (`watchAuthPollInvariants.test.ts`) gives for its equivalent
///   gap: code review.
///
/// Housekeeping notes on the tokenizer (still used for the tripwires and the
/// non-auth pins at the bottom of this file): the round-3
/// "segments-reconstruct-the-source" self-check was REMOVED as decorative —
/// it compared segment text only, never segment labels, and every branch
/// slices contiguous ranges, so it could not fail; keeping it would be
/// another overclaim. `TokenizeDesyncError` — the part that actually works —
/// stays: every comment/string form throws with a location if its terminator
/// is missing, so a desync fails loudly instead of blanking the rest of a
/// file (#488 G3).

const REPO = join(import.meta.dirname, "..", "..");

const WATCH_APP = join(REPO, "ios", "App", "SendLogWatch Watch App");
const HEALTH_PLUGIN = join(
  REPO, "native-plugins", "sendlog-health", "ios", "Sources", "SendLogHealth",
);
const AUTH_BRIDGE = join(
  REPO, "native-plugins", "sendlog-auth-bridge", "ios", "Sources", "SendLogAuthBridge",
);
const IOS_ROOT = join(REPO, "ios");
const NATIVE_PLUGINS_ROOT = join(REPO, "native-plugins");
// Test targets never ship, so they're not a live #265 reachability surface —
// they're allowed to `import Supabase` (e.g. to build fixtures) without
// living inside one of the two scanned directories above.
const TEST_TARGETS_EXEMPT_FROM_SCAN = [join(REPO, "ios", "App", "SendLogWatchTests")];

/// The two files allowed to hold a `SupabaseClient` (#502). Everything the
/// compiler-enforcement story rests on is asserted against exactly these.
const FACADES = [
  { dir: WATCH_APP, file: join(WATCH_APP, "Services", "SupabaseService.swift") },
  { dir: HEALTH_PLUGIN, file: join(HEALTH_PLUGIN, "HealthConfig.swift") },
];

// Directories that hold build output, not source — walking into them is both
// slow (hundreds of MB once a local `swift build`/`swift test` has run) and
// wrong (vendored dependency source would itself legitimately `import
// Supabase` and touch `.auth`, which has nothing to do with reachability
// from THIS repo's own code).
const SKIP_DIR_NAMES = new Set([".build", ".swiftpm", "DerivedData", "Packages", "Pods"]);

function swiftFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    if (entry.startsWith(".") || SKIP_DIR_NAMES.has(entry)) return [];
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return swiftFiles(path);
    return path.endsWith(".swift") ? [path] : [];
  });
}

type Segment = { text: string; kind: "code" | "comment" | "string" };

interface StringForm {
  open: string;
  close: string;
  // Whether a backslash escapes the next character while scanning for
  // `close` — needed for both single-character quotes AND `"""` (Swift's
  // `\"""` escapes just the first quote of what would otherwise read as the
  // closing delimiter — #488 G3).
  escapes: boolean;
  // If set, this text (`\(` for Swift) starts a string interpolation: the
  // interpolation body is scanned for its matching close paren (tracking
  // depth, and skipping any NESTED string literal wholesale so ITS parens
  // don't confuse the count) and re-tokenized as real CODE, instead of being
  // blanked as string content. Without this, an accessor written inside a
  // string interpolation is invisible to the accessor-only scan (#488 G1) —
  // exactly the realistic "one debug log line" case round 1's F1 named.
  // Not set for raw strings (`#"…"#`), which interpolate with `\#(` instead
  // — see the module doc comment's residual list.
  interpolationPrefix?: string;
}

/// Thrown when the tokenizer cannot find a comment's or string's terminator
/// before EOF — which means it lost sync, not that the input is unusual
/// Swift/TS. #488 G3: a silent desync used to blank the rest of the file
/// (everything after it read as one giant "string" segment), which is the
/// worst failure mode a pin can have — a miss that looks exactly like a
/// pass. Throwing converts every desync mode, including ones not
/// specifically handled below, from "silently green" to "fails with a
/// location", which is why this exists as a dedicated error rather than
/// e.g. returning a null/partial result.
class TokenizeDesyncError extends Error {
  constructor(what: string, sourceLabel: string, index: number) {
    super(`tokenize(): unterminated ${what} at index ${index} of ${sourceLabel} — the lexer lost sync (#488 G3)`);
  }
}

// Scans forward from `start` (the index right after an interpolation's
// opening `\(`) tracking paren depth, so `\(a(b))` and even
// `\(foo("weird)string"))` end at the correct matching `)` — a NESTED
// string literal's own parens must not affect the count, so its content is
// skipped wholesale via the same open/close/escapes rules as top-level
// scanning. Returns the index just past that `)`, or throws if EOF is
// reached first (an unterminated interpolation is exactly a desync — #488
// G1+G3).
function findInterpolationEnd(
  src: string,
  start: number,
  stringForms: StringForm[],
  sourceLabel: string,
): number {
  let depth = 1;
  let i = start;
  while (i < src.length && depth > 0) {
    let matchedNested = false;
    for (const form of stringForms) {
      if (!src.startsWith(form.open, i)) continue;
      let j = i + form.open.length;
      while (j < src.length && !src.startsWith(form.close, j)) {
        j += form.escapes && src[j] === "\\" ? 2 : 1;
      }
      if (j >= src.length) {
        throw new TokenizeDesyncError(`nested string literal (inside interpolation)`, sourceLabel, i);
      }
      i = j + form.close.length;
      matchedNested = true;
      break;
    }
    if (matchedNested) continue;
    if (src[i] === "(") depth++;
    else if (src[i] === ")") depth--;
    i++;
  }
  if (depth > 0) {
    throw new TokenizeDesyncError("string interpolation", sourceLabel, start);
  }
  return i;
}

// A Swift raw string opener is one-or-more `#` immediately followed by `"`
// (`#"…"#`, `##"…"##`, …) — arbitrary hash count, both ends must match
// (#488 G3: a fixed single-`#` form let a `##"…"##` literal's `"#` close
// early and desync the rest of the file). Returns the hash count, or 0 if
// `i` isn't a raw-string opener (e.g. a `#if`/`#else` directive, where the
// `#` is followed by a letter, not `"`).
function rawStringHashCountAt(src: string, i: number): number {
  let hashes = 0;
  while (src[i + hashes] === "#") hashes++;
  return src[i + hashes] === '"' ? hashes : 0;
}

/// A small shared tokenizer for `//` / `/* … */` comments (block comments
/// nest, per Swift — #488 G5) plus a caller-supplied list of quoted-string
/// forms (checked in the given order, so put more specific/longer
/// delimiters first — e.g. `"""` before `"`) and Swift's arbitrary-hash-count
/// raw strings. String interpolation is re-entered as code where
/// `interpolationPrefix` says to (#488 G1); every comment/string form throws
/// rather than silently swallowing the rest of the file if its terminator is
/// missing (#488 G3). Not a full lexer for either language — good enough for
/// ordinary application source, not text built specifically to evade a scan.
/// Since #502 nothing that matters rests solely on it: it feeds the façade
/// tripwires and the non-auth pins, while the compiler and the raw-text
/// greps carry the reachability invariant (see the module doc comment).
function tokenize(src: string, stringForms: StringForm[], sourceLabel = "<input>"): Segment[] {
  const segments: Segment[] = [];
  let i = 0;
  outer: while (i < src.length) {
    if (src.startsWith("//", i)) {
      const end = src.indexOf("\n", i);
      const j = end === -1 ? src.length : end;
      segments.push({ text: src.slice(i, j), kind: "comment" });
      i = j;
      continue;
    }
    if (src.startsWith("/*", i)) {
      let depth = 1;
      let j = i + 2;
      while (j < src.length && depth > 0) {
        if (src.startsWith("/*", j)) {
          depth++;
          j += 2;
        } else if (src.startsWith("*/", j)) {
          depth--;
          j += 2;
        } else {
          j++;
        }
      }
      if (depth > 0) throw new TokenizeDesyncError("block comment", sourceLabel, i);
      segments.push({ text: src.slice(i, j), kind: "comment" });
      i = j;
      continue;
    }
    const rawHashes = rawStringHashCountAt(src, i);
    if (rawHashes > 0) {
      const openLen = rawHashes + 1;
      const closeDelim = '"' + "#".repeat(rawHashes);
      let j = i + openLen;
      while (j < src.length && !src.startsWith(closeDelim, j)) j++;
      if (j >= src.length) throw new TokenizeDesyncError("raw string literal", sourceLabel, i);
      j += closeDelim.length;
      segments.push({ text: src.slice(i, j), kind: "string" });
      i = j;
      continue;
    }
    for (const form of stringForms) {
      if (!src.startsWith(form.open, i)) continue;
      let cursor = i + form.open.length;
      let pieceStart = i;
      let closed = false;
      while (cursor < src.length) {
        if (src.startsWith(form.close, cursor)) {
          cursor += form.close.length;
          closed = true;
          break;
        }
        if (form.interpolationPrefix && src.startsWith(form.interpolationPrefix, cursor)) {
          const bodyStart = cursor + form.interpolationPrefix.length;
          segments.push({ text: src.slice(pieceStart, bodyStart), kind: "string" });
          const afterBody = findInterpolationEnd(src, bodyStart, stringForms, sourceLabel);
          const body = src.slice(bodyStart, afterBody - 1); // exclude the matching `)`
          segments.push(...tokenize(body, stringForms, `${sourceLabel} (interpolation)`));
          segments.push({ text: src.slice(afterBody - 1, afterBody), kind: "string" }); // the `)`
          pieceStart = afterBody;
          cursor = afterBody;
          continue;
        }
        cursor += form.escapes && src[cursor] === "\\" ? 2 : 1;
      }
      if (!closed) throw new TokenizeDesyncError("string literal", sourceLabel, i);
      segments.push({ text: src.slice(pieceStart, cursor), kind: "string" });
      i = cursor;
      continue outer;
    }
    let j = i + 1;
    scan: while (j < src.length) {
      if (src.startsWith("//", j) || src.startsWith("/*", j)) break scan;
      if (rawStringHashCountAt(src, j) > 0) break scan;
      for (const form of stringForms) {
        if (src.startsWith(form.open, j)) break scan;
      }
      j++;
    }
    segments.push({ text: src.slice(i, j), kind: "code" });
    i = j;
  }
  // (The round-3 "segments reconstruct the source" self-check that used to
  // live here was removed as decorative — see the module doc comment.)
  return segments;
}

// Blanks a segment's content while preserving every newline, so a match
// index computed against the joined-back string still maps to the correct
// original line number.
function blank(text: string): string {
  return text.replace(/[^\n]/g, " ");
}

const SWIFT_STRINGS: StringForm[] = [
  { open: '"""', close: '"""', escapes: true, interpolationPrefix: "\\(" },
  { open: '"', close: '"', escapes: true, interpolationPrefix: "\\(" },
];

const TS_STRINGS: StringForm[] = [
  { open: "`", close: "`", escapes: true },
  { open: '"', close: '"', escapes: true },
  { open: "'", close: "'", escapes: true },
];

/// Comments stripped, string-literal CONTENT preserved — for assertions that
/// need to read real Swift text, including string contents (e.g. the
/// `"refreshToken"` dictionary key checked below).
function swiftCode(path: string): string {
  return tokenize(readFileSync(path, "utf8"), SWIFT_STRINGS, path)
    .map((s) => (s.kind === "comment" ? blank(s.text) : s.text))
    .join("");
}

/// Comments AND string-literal contents both stripped — for the
/// AuthClient-reachability tripwires only. A string's content (a URL, a
/// Keychain key name, a doc line quoted in a log message) must never be
/// mistaken for real code touching `.auth`. String INTERPOLATION is the
/// exception — `tokenize()` re-enters `\(…)` as code, so an accessor written
/// inside a string interpolation stays visible here (#488 G1).
function swiftCodeForAccessorScan(path: string): string {
  return tokenize(readFileSync(path, "utf8"), SWIFT_STRINGS, path)
    .map((s) => (s.kind === "code" ? s.text : blank(s.text)))
    .join("");
}

/// Same idea as `swiftCode`, for the two plain-TS reads below — a `//`
/// inside a string literal used to truncate those the same way (round 1 only
/// fixed the Swift side; this closes the identical shape in this same file).
function tsCodeWithoutComments(path: string): string {
  return tokenize(readFileSync(path, "utf8"), TS_STRINGS, path)
    .map((s) => (s.kind === "comment" ? blank(s.text) : s.text))
    .join("");
}

function sources(...dirs: string[]): { path: string; code: string }[] {
  return dirs.flatMap((dir) =>
    swiftFiles(dir).map((path) => ({
      path: path.slice(REPO.length + 1),
      code: swiftCode(path),
    })),
  );
}

function accessorScanSources(...dirs: string[]): { path: string; scanText: string }[] {
  return dirs.flatMap((dir) =>
    swiftFiles(dir).map((path) => ({
      path: path.slice(REPO.length + 1),
      scanText: swiftCodeForAccessorScan(path),
    })),
  );
}

// `${path}:${line}: ${the offending line, trimmed}` — a red run used to say
// only `expected [ 'ios/.../Foo.swift' ] to deeply equal []`, no line, no
// reason (#488 F4).
function offenseAt(path: string, text: string, index: number): string {
  const line = text.slice(0, index).split("\n").length;
  const lineStart = text.lastIndexOf("\n", index) + 1;
  const lineEndIdx = text.indexOf("\n", index);
  const lineText = text.slice(lineStart, lineEndIdx === -1 ? text.length : lineEndIdx).trim();
  return `${path}:${line}: ${lineText}`;
}

// The full source line containing `index` — for line-scoped checks like
// "this declaration must be on a `private` line".
function lineAt(text: string, index: number): string {
  const lineStart = text.lastIndexOf("\n", index) + 1;
  const lineEndIdx = text.indexOf("\n", index);
  return text.slice(lineStart, lineEndIdx === -1 ? text.length : lineEndIdx);
}

describe("the refreshing accessor is unreachable by construction (#502)", () => {
  // These three assertions are the premises the compiler-enforcement story
  // rests on (module doc comment, premises 1–2). The first two run on RAW
  // file text on purpose: with no lexer there is nothing to desync, so an
  // identifier hidden inside a string, a comment trick, or a regex literal
  // is still seen. The trade is a possible LOUD false positive on a future
  // comment that spells out `SupabaseClient` in a non-façade file — the fix
  // for that is rewording the comment, never weakening this pin.

  it("each façade holds its client in a `private static let` — the compiler seals every member path to `.auth` from outside the façade file", () => {
    for (const { file } of FACADES) {
      const raw = readFileSync(file, "utf8");
      expect(raw, file.slice(REPO.length + 1)).toMatch(
        /\bprivate static let client: SupabaseClient\b/,
      );
    }
  });

  it("no file outside the façades even names `SupabaseClient` (raw text — nothing can hide an occurrence)", () => {
    // This is what makes the `private` above sufficient: with the type
    // unnameable elsewhere in the guarded directories, there is no second
    // client to construct, no typealias to launder one through, and nothing
    // to dot `.auth` off. (`SupabaseClientOptions` doesn't match — `\b`
    // requires the identifier to end after "Client".)
    const facadeFiles = new Set(FACADES.map((f) => f.file));
    const offenders = [WATCH_APP, HEALTH_PLUGIN].flatMap((dir) =>
      swiftFiles(dir)
        .filter((path) => !facadeFiles.has(path))
        .flatMap((path) => {
          const raw = readFileSync(path, "utf8");
          return [...raw.matchAll(/\bSupabaseClient\b/g)].map((m) =>
            offenseAt(path.slice(REPO.length + 1), raw, m.index),
          );
        }),
    );
    expect(offenders).toEqual([]);
  });

  it("every SupabaseClient-typed declaration inside a façade is on a `private` line", () => {
    // Guards the façades' own surface: a `static let leaked: SupabaseClient`
    // or `static func client() -> SupabaseClient` would hand the whole
    // target the client back and silently void the compiler argument. A
    // declaration split across lines puts the type annotation on a line
    // without `private`, which fails here loudly — the false-positive
    // direction, never the silent one.
    for (const { file } of FACADES) {
      const raw = readFileSync(file, "utf8");
      const offenders = [...raw.matchAll(/(?::|->)\s*SupabaseClient\b/g)]
        .filter((m) => !/\bprivate\b/.test(lineAt(raw, m.index)))
        .map((m) => offenseAt(file.slice(REPO.length + 1), raw, m.index));
      expect(offenders).toEqual([]);
    }
  });

  it("never names AuthClient/GoTrueClient in code, anywhere in either directory", () => {
    // `import Supabase` re-exports the Auth product, so `AuthClient` is
    // directly constructible — and a self-built AuthClient contains no
    // `.auth` member access for the tripwires below to see. Runs on the
    // code-only view (not raw text) because comments legitimately discuss
    // `AuthClient` (e.g. WatchSessionStore's docs).
    const offenders = accessorScanSources(WATCH_APP, HEALTH_PLUGIN).flatMap(
      ({ path, scanText }) =>
        [...scanText.matchAll(/\b(?:AuthClient|GoTrueClient)\b/g)].map((m) =>
          offenseAt(path, scanText, m.index),
        ),
    );
    expect(offenders).toEqual([]);
  });
});

/// Every supabase-swift call that can mint, rotate or spend a refresh token.
/// `auth.session` (as opposed to `currentSession`) refreshes when the stored
/// access token has expired — the discovery that produced #196 — and
/// `setSession` refreshes outright when handed an expired access token, which
/// is what #196's guards were left standing in front of.
const ROTATING_CALLS = [
  { pattern: /\.auth\.setSession\s*\(/, name: "auth.setSession" },
  { pattern: /\.auth\.session\b/, name: "auth.session (refreshes when expired)" },
  { pattern: /\.auth\.refreshSession\s*\(/, name: "auth.refreshSession" },
  { pattern: /\.auth\.signIn/, name: "auth.signIn" },
  { pattern: /\.auth\.signOut\s*\(/, name: "auth.signOut" },
  { pattern: /\brefreshToken\s*[:=]/, name: "a refreshToken argument/property" },
];

// `.auth` preceded by an identifier character, `)`, `]`, `?`/`!` (optional
// chaining/force-unwrap — `client?.auth`, `client!.auth`, #488 G2), `}`/`>`
// (`{ … }.auth`, `Foo<Bar>.auth`), or a keypath backslash — i.e. real member
// access — NOT preceded by whitespace or punctuation, which is how
// implicit-member syntax referencing an unrelated enum case always looks
// (`case .auth:`, `forKey: .auth`, `return .auth`).
const AUTH_PROPERTY_ACCESS = /[\w)\]\\?!}>]\.auth\b/g;

describe("no session-consuming native client may hold or spend a refresh token (#265)", () => {
  // Since #502 these scans are tripwires layered under the compiler, not the
  // enforcement itself (module doc comment). They matter most for the two
  // façade files, which legitimately hold the client and are the one place
  // the compiler cannot police. They keep running over BOTH whole
  // directories because post-#502 there is no legitimate `.auth` member
  // access anywhere in them — a match is never a false positive to engineer
  // around, and the wide net also covers a façade leak the #502 checks above
  // failed to anticipate.
  const consumers = accessorScanSources(WATCH_APP, HEALTH_PLUGIN);

  it("finds the sources it is supposed to be guarding", () => {
    // A path typo would turn every assertion below into a vacuous pass, which
    // is precisely the failure mode this whole file exists to prevent.
    expect(consumers.length).toBeGreaterThan(10);
    expect(consumers.map((s) => s.path)).toContain(
      "ios/App/SendLogWatch Watch App/Services/SupabaseService.swift",
    );
    expect(consumers.map((s) => s.path)).toContain(
      "native-plugins/sendlog-health/ios/Sources/SendLogHealth/HealthConfig.swift",
    );
  });

  for (const { pattern, name } of ROTATING_CALLS) {
    it(`never calls ${name}`, () => {
      const scan = new RegExp(pattern.source, "g");
      const offenders = consumers.flatMap(({ path, scanText }) =>
        [...scanText.matchAll(scan)].map((m) => offenseAt(path, scanText, m.index)),
      );
      expect(offenders).toEqual([]);
    });
  }

  it("never touches AuthClient at all — no `.auth` property access, direct or aliased (#196, #488, #502)", () => {
    // `consumers` is comment-AND-string-stripped (`swiftCodeForAccessorScan`).
    // There is zero legitimate use of `.auth` as member access anywhere in
    // either directory: both clients are built with an `accessToken` closure,
    // never construct or reach an AuthClient, and since #502 sit `private`
    // behind their façades.
    const offenders = consumers.flatMap(({ path, scanText }) =>
      [...scanText.matchAll(AUTH_PROPERTY_ACCESS)].map((m) => offenseAt(path, scanText, m.index)),
    );
    expect(offenders).toEqual([]);
  });

  it("configures each façade's client with a non-refreshing accessToken provider", () => {
    // The seam that makes "no AuthClient" structural rather than incidental:
    // a client built with an `accessToken` provider never consults an
    // AuthClient, so there is no session for the SDK to recover or renew.
    // Scoped to the façades because the #502 checks above pin them as the
    // only two client-construction sites.
    for (const { file } of FACADES) {
      expect(swiftCodeForAccessorScan(file), file.slice(REPO.length + 1)).toMatch(
        /accessToken:\s*\{/,
      );
    }
  });
});

describe("every Supabase-importing Swift file lives inside a scanned directory (#488 F3)", () => {
  it("has no importer outside WATCH_APP / HEALTH_PLUGIN, except test targets that ship nothing", () => {
    // An accessor helper placed in a THIRD directory (e.g.
    // `sendlog-health-core`, already a real dependency of the health plugin
    // via `Package.swift`) and called from a guarded file with no `.auth` at
    // the call site is invisible to every check above, which only ever walks
    // WATCH_APP + HEALTH_PLUGIN. This doesn't close that hole — no text scan
    // of two fixed directories can — but it converts it from silent to loud:
    // the moment ANY file outside those two (and the one exempt test target)
    // starts importing Supabase, this goes red and has to be looked at,
    // rather than silently gaining a new, unchecked #265 surface.
    //
    // Matches every supabase-swift product, not just the `Supabase` umbrella
    // (#488 G4): `AuthClient` itself lives in the separately importable
    // `Auth` module, so a file can `import Auth`, hold one, and never write
    // the word "Supabase" — reopening the exact hole this assertion exists
    // to close, by module name instead of by directory.
    const importers = [...swiftFiles(IOS_ROOT), ...swiftFiles(NATIVE_PLUGINS_ROOT)].filter((p) =>
      /^\s*import\s+(Supabase|Auth|PostgREST|Realtime|Storage|Functions)\b/m.test(
        readFileSync(p, "utf8"),
      ),
    );

    const outsideScannedDirs = importers.filter((p) => {
      if (p.startsWith(WATCH_APP + "/") || p.startsWith(HEALTH_PLUGIN + "/")) return false;
      return !TEST_TARGETS_EXEMPT_FROM_SCAN.some((dir) => p.startsWith(dir + "/"));
    });

    expect(outsideScannedDirs.map((p) => p.slice(REPO.length + 1))).toEqual([]);
  });
});

describe("the phone relays an access token only (#265)", () => {
  it("the WatchConnectivity bridge never forwards a refresh token", () => {
    const [bridge] = sources(AUTH_BRIDGE);
    // #368 temporarily supplies one fixed invalid literal to the native WC
    // dictionary for the pre-#270 decoder's presence guard. It must never be
    // accepted from JS or sourced from a real Supabase session.
    expect(bridge!.code).not.toMatch(/getString\(\s*"refreshToken"/);
    expect(bridge!.code.match(/"refreshToken"\s*:/g)).toHaveLength(1);
    expect(bridge!.code).toMatch(
      /"refreshToken"\s*:\s*SessionRelay\.legacyRefreshTokenSentinel/,
    );
  });

  it("stamps every relayed payload with something that always changes (#266)", () => {
    // An application context identical to the one already set delivers
    // nothing, so answering a watch's pull while the phone's token is still
    // valid would relay the same triple to no effect. Whatever the true cause
    // of the pull failure, a payload that is never byte-identical removes this
    // one from the table.
    const [bridge] = sources(AUTH_BRIDGE);
    expect(bridge!.code).toMatch(/relayId.*UUID\(\)/s);
  });

  it("neither JS relay reads session.refresh_token", () => {
    for (const file of ["watchAuthRelay.ts", "healthSync.ts"]) {
      const src = tsCodeWithoutComments(join(REPO, "src", "lib", file));
      expect(src, file).not.toMatch(/refresh_token/);
    }
  });
});

describe("useAuth detaches every listener it attaches (#266)", () => {
  const src = readFileSync(join(REPO, "src", "hooks", "useAuth.ts"), "utf8");

  it("keeps the sessionRequested handle and removes it on cleanup", () => {
    // The handle used to be discarded inside `onWatchSessionRequest`, so the
    // effect's cleanup — which does unsubscribe the other three — had nothing
    // to remove and every remount left another listener on a stale closure.
    expect(src).toMatch(/=\s*onWatchSessionRequest\(/);
    expect(src).toMatch(/watchRequest\.then\(\(handle\) => handle\?\.remove\(\)\)/);
  });
});

describe("watch diagnostics events stay transition-driven (#368)", () => {
  const [bridge] = sources(AUTH_BRIDGE);

  it("does not refresh watch-info consumers for every live force beat", () => {
    expect(bridge!.code).toMatch(/let buildChanged =/);
    expect(bridge!.code).toMatch(/let pendingChanged =/);
    // #475 F1: quarantine rides the same transition-driven trigger — a
    // quarantine-only change (pending count unchanged) must still refresh
    // watch-info consumers, so it belongs in the same OR-chain, not a
    // separate always-refresh path.
    expect(bridge!.code).toMatch(/let quarantinedChanged =/);
    // #475 F13: same for the .stuckRetrying subset — it can change (the F12
    // resurrection path) without the total changing.
    expect(bridge!.code).toMatch(/let quarantinedStuckChanged =/);
    expect(bridge!.code).toMatch(
      /if buildChanged \|\| pendingChanged \|\| quarantinedChanged \|\| quarantinedStuckChanged \|\| kind == "requestSession" \|\| kind == "queueStatus"/,
    );
  });

  it("records build and queue transitions through change-returning stores", () => {
    expect(bridge!.code).toMatch(/static func record\(_ identity: BuildIdentity\) -> Bool/);
    expect(bridge!.code).toMatch(/static func record\(_ count: Int\) -> Bool/);
    // #475 F1/F13: the quarantine stores follow the identical
    // change-returning shape as WatchSyncStore, so the same generic
    // assertion already covers them — this pins that FOUR stores exist
    // total (build + pending + quarantined + quarantined-stuck), not just two.
    expect(
      [...bridge!.code.matchAll(/static func record\(_ count: Int\) -> Bool/g)].length,
    ).toBeGreaterThanOrEqual(3);
  });

  it("re-reads watch info after listener registration resolves", () => {
    const hook = readFileSync(join(REPO, "src", "hooks", "useWatchInfo.ts"), "utf8");
    expect(hook).toMatch(/\.listen\(refresh\)[\s\S]*\.then\(\(handle\) => \{/);
    expect(hook).toMatch(/if \(!active\)[\s\S]*handle\?\.remove\(\)[\s\S]*return null/);
    expect(hook).toMatch(/return null;[\s\S]*refresh\(\);[\s\S]*return handle/);
  });

  it("keeps Account and History on the shared live watch-info hook (#369)", () => {
    for (const component of ["AccountSheet.tsx", "HistoryView.tsx"]) {
      const src = readFileSync(join(REPO, "src", "components", component), "utf8");
      expect(src, component).toMatch(/useWatchInfo\(\)/);
    }
  });
});
