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
/// find; it is a compile error, verified by mutation probes in both #502
/// rounds (all three of round 3's residual holes among them). That holds
/// exactly as long as the premises below do — the #502 review (F1)
/// demonstrated that a façade quietly re-exporting its client turns the
/// newline-split accessor back into legal Swift, which is why premise 1 is
/// now an allow-list over the façades' whole declaration surface rather
/// than a hunt for one type annotation.
///
/// **The COMPILER is the guarantee. This file is a secondary net** — over
/// the two façade files (where the compiler enforces nothing, because they
/// hold the client legitimately) plus an identifier tripwire everywhere
/// else. Nothing below seals anything on its own; the pins exist so that
/// breaking a premise of the compiler argument is loud instead of silent,
/// and they are certified only against the mutations that were actually
/// run (listed per pin below and in HANDOFF.md), not against every
/// spelling Swift permits.
///
/// This file has now failed FIVE rounds the same way (#488 rounds 0–3,
/// #502 review R2-F1), every time because incidental text — a comment, a
/// string literal, a URL — was allowed to participate in a decision about
/// a DECLARATION: substrings fell to an alias; a comment stripper cut a
/// line at a `//` inside a string; a hand-rolled tokenizer minted new
/// defects; a whole-file positive match was satisfied by a comment; a
/// `\bprivate\b` word-search over the raw line was disarmed by a trailing
/// `// TODO: make private` comment. The standing rule for every matcher
/// here: **incidental text may TRIP a check (a loud false positive, fixed
/// by rewording), but must never be able to SATISFY one.** Write the
/// mutation before the matcher.
///
/// The premises, and what pins them:
///
/// 1. **Each façade file's declaration surface is exactly its allow-list.**
///    Any line carrying a declaration keyword (`static`, `class`,
///    `struct`, `actor`, `enum`, `protocol`, `extension`, `typealias`) and
///    any column-0 code line must BEGIN with `private` (position-anchored
///    on the trimmed line — R2-F1's fix; column-0 lines get no private
///    escape at all) or appear verbatim in `FACADES[].allowedLines`.
///    Mutation-tested spellings that go red with file:line: inferred-type
///    `static let shared = client` bare (review F1's shape), the same with
///    a trailing "…not private…" comment and with a `"private"` string
///    literal on the line (R2-F1's shapes), a computed `static var` with a
///    trailing comment, a nested `enum Inner` and its member, a
///    split-modifier `static` on its own line, a same-file
///    `extension SupabaseService`, and a column-0 global. The legal
///    `static private let` spelling reads as an offender — loud direction,
///    reorder the modifiers. Spellings beyond these are NOT certified;
///    a new declaration shape belongs in a claim only after a mutation
///    shows it red. The line-anchored positive match for
///    `private static let client: SupabaseClient` is a label on the same
///    fact, not a second enforcement.
///    Each façade file contains nothing but the façade enum — NOT because
///    `private` is file-scoped (it is not: a neighbour type in the same
///    file cannot reach the client, compiler-verified in both #502 review
///    rounds), but because this pin holds the file's WHOLE surface to a
///    two-line allow-list, which is only possible if the façade is all
///    there is (`HealthSessionStore` moved out so its members wouldn't
///    read as offenders). The same-file shape that genuinely shares the
///    client is an `extension` of the façade type, and any non-private
///    `extension` line is an offender here.
/// 2. **There is no other client to reach.** The identifier
///    `SupabaseClient` appears nowhere in either guarded directory outside
///    the two façade files (raw text — a construction hidden inside a
///    string, comment trick, or regex literal is still seen), and
///    `AuthClient`/`GoTrueClient` — directly constructible even outside
///    the façades (it COMPILES; #502 review F3 verified the compiler does
///    not seal this), with no `.auth` member text for the tripwires to
///    see — appear on no line of either directory whose first
///    non-whitespace isn't `//`. Real code cannot live on a `//` line, so
///    the tokenizer blind spots (bare regex literals, raw-string
///    interpolation — both demonstrated hiding an `AuthClient(…)` from the
///    tokenized view in review F3) do not apply to this raw scan. The
///    tokenized code-only twin runs alongside as the zero-false-positive
///    complement.
/// 3. **The SDK is importable only inside the guarded directories** — the
///    #488 allow-list over all six separately-importable supabase-swift
///    products (`Supabase`, `Auth`, `PostgREST`, `Realtime`, `Storage`,
///    `Functions`), kept unchanged below.
///
/// The pre-#502 accessor scans (ROTATING_CALLS / the `.auth` member-access
/// scan, tokenizer-based) are KEPT as tripwires, no longer as the line of
/// defence. Post-#502 there is no legitimate `.auth` member access anywhere
/// in either directory, so any future match is dead code or an attack,
/// never a false positive to engineer around.
///
/// **What this arrangement does NOT cover, stated precisely (five earlier
/// versions of this docstring overclaimed; every claim below is matched to
/// a mutation that was actually run — see HANDOFF.md for the outputs):**
///
/// - **The BODIES of the façades' members are trusted code.** The surface
///   allow-list pins what the façades DECLARE (in the mutation-tested
///   spellings enumerated in premise 1 — not "any spelling") — but what an
///   allowed or private member's body does is guarded only by the
///   tokenized tripwires, which retain their known evasions there:
///   `\#(…)` raw-string interpolation is blanked as opaque string content;
///   a bare regex literal holding a quote can desync string pairing;
///   `client.\n    auth` split across a newline has no `.auth` substring.
///   An adversarial edit inside `makeClient()` (or the health façade's
///   init closure) could hide `client.auth.…` from every automated check
///   in this file. The guard is review of façade diffs — two small files
///   whose only job is this invariant. Outside the façade files those same
///   shapes are compile errors for the client path (mutation-verified in
///   both #502 rounds) and raw-text-visible for the identifier pins.
/// - **Declaration spellings outside the tested set.** These are
///   line-based raw-text checks; a spelling that puts a declaration on
///   lines the matchers misread may pass silently — R2-F1 was exactly
///   that, discovered by the reviewer, not by this list. The pin certifies
///   the tested set; novelty is review's job.
/// - **Name-free access.** These pins hunt identifiers on non-comment
///   lines. An accessor reached without its name ever appearing on one — a
///   future SDK API that returns an `AuthClient` under another name, or a
///   rotating accessor added under a name never seen — is review's job,
///   same as the precedent (`watchAuthPollInvariants.test.ts`) states for
///   its equivalent gap. (Swift has no runtime string-to-type construction
///   for these non-`@objc` types, so this is about future API surface, not
///   a trick available today.)
/// - **The SDK version is part of the trust boundary.** The compiler
///   argument holds because `PostgrestQueryBuilder` (supabase-swift
///   v2.51.0) has no member path back to the client or any auth surface —
///   verified against that revision only. An SDK bump that adds such a
///   member would void the argument without any pin here going red;
///   re-review the façade's return type on every supabase-swift upgrade.
/// - **Hand-rolled HTTP.** A `URLSession` POST to `/auth/v1/token` with the
///   committed anon key involves no SDK type; neither the compiler barrier
///   nor anything in this file sees it. The operative backstop is #265's,
///   not this file's: there is no refresh token on the device or the wire to
///   spend, so a hand-rolled call would need credentials the native side
///   does not hold. The same backstop bounds a self-built `AuthClient`
///   slipping every pin: it would still have nothing to rotate, and both
///   session stores purge supabase-swift's Keychain item on every launch.
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
///
/// `allowedLines` is each façade's ENTIRE permitted non-private declaration
/// surface, verbatim (trimmed): the enum itself and the one `from(_:)`
/// accessor. Every other line that declares anything reachable from outside
/// the file must say `private`. Extend this list CONSCIOUSLY — a new narrow
/// accessor gets its line added here in the same PR that adds it, so the
/// diff shows both sides.
const FACADES = [
  {
    dir: WATCH_APP,
    file: join(WATCH_APP, "Services", "SupabaseService.swift"),
    allowedLines: new Set([
      "enum SupabaseService {",
      "static func from(_ table: String) -> PostgrestQueryBuilder {",
    ]),
  },
  {
    dir: HEALTH_PLUGIN,
    file: join(HEALTH_PLUGIN, "HealthConfig.swift"),
    allowedLines: new Set([
      "enum HealthConfig {",
      "static func from(_ table: String) -> PostgrestQueryBuilder {",
    ]),
  },
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

describe("the refreshing accessor is unreachable by construction (#502)", () => {
  // These are secondary premise tripwires, not the load-bearing guarantee:
  // the compiler is load-bearing for the #502 access boundary. The source
  // checks are certified only for the named mutation-tested spellings listed
  // in the module doc comment and HANDOFF.md; novel declaration spellings
  // remain outside the contract, and a raw-text scan can still miss them.
  // The positive match is only a label on one façade fact, not independent
  // or compensating enforcement.

  it("each façade holds its client in a `private static let` (line-anchored — a comment quoting this phrase cannot satisfy it)", () => {
    // `^\s*` + `m`: only a line whose first non-whitespace text IS the
    // declaration matches. A `//`/`///` comment line starts with slashes and
    // never matches (#502 review F2 defeated the previous whole-file match
    // with exactly such a comment).
    for (const { file } of FACADES) {
      const raw = readFileSync(file, "utf8");
      expect(raw, file.slice(REPO.length + 1)).toMatch(
        /^\s*private static let client: SupabaseClient\b/m,
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

  it("each façade's declaration surface is exactly its allow-list — every other declaring line must BEGIN with `private` (#502 review F1/F2, R2-F1)", () => {
    // The pre-review pin hunted the type annotation `: SupabaseClient`, so a
    // façade edit `static let shared = client` — type INFERRED — re-exported
    // the client with a clean compile and green pins (review F1). This scan
    // doesn't look for the type at all: it holds the façade file's whole
    // declaration surface to the allow-list.
    //
    // Two triggers, both raw-line-based:
    // - any line containing a declaration keyword that can widen the
    //   surface (`static` catches every enum member incl. split-modifier
    //   spellings; `class`/`struct`/`actor`/`enum`/`protocol`/`extension`/
    //   `typealias` catch nested types, aliases, and — the one same-file
    //   shape that really does share the `private` client — an
    //   `extension` of the façade type);
    // - any column-0 code line (file-scope `let leaked = client` or
    //   `func leak()` declares a reachable global without any keyword the
    //   first trigger sees). Column-0 lines get NO private escape at all.
    // `//`-comment lines are skipped — real code cannot live on one; body
    // lines (indented `let`/`var` locals) carry none of the trigger words.
    // Enum stored instance properties are a compile error and a no-case
    // enum has no instances, so instance members don't need a trigger.
    //
    // The private test is POSITION-ANCHORED to the start of the trimmed
    // line, not a word-search over the raw line: review R2-F1 disarmed the
    // previous `\bprivate\b` test with a trailing `// TODO: make private`
    // comment (and with a `"private"` string literal) — incidental text
    // must never be able to SATISFY a check about a declaration. Swift
    // puts the access modifier first in every spelling used here; the
    // legal-but-unused `static private let` reads as an offender and gets
    // its modifiers reordered — the loud direction.
    const SURFACE_TRIGGER = /\b(?:static|class|struct|actor|enum|protocol|extension|typealias)\b/;
    for (const { file, allowedLines } of FACADES) {
      const raw = readFileSync(file, "utf8");
      const offenders = raw.split("\n").flatMap((line, i) => {
        const trimmed = line.trim();
        if (trimmed === "" || trimmed.startsWith("//")) return [];
        if (allowedLines.has(trimmed)) return [];
        const topLevelCode = /^\S/.test(line) && !/^(?:import\s|\}|#)/.test(line);
        const declares = SURFACE_TRIGGER.test(line) && !/^private\s/.test(trimmed);
        if (!topLevelCode && !declares) return [];
        return [`${file.slice(REPO.length + 1)}:${i + 1}: ${trimmed}`];
      });
      expect(offenders).toEqual([]);
    }
  });

  it("never names AuthClient/GoTrueClient outside a `//` comment, anywhere in either directory (raw text)", () => {
    // `import Supabase` re-exports the Auth product, so `AuthClient` is
    // directly constructible OUTSIDE the façades too — the compiler seals
    // only the façades' clients, and a self-built AuthClient contains no
    // `.auth` member access for the tripwires below to see. Text is the
    // only guard here, so it must be the un-desyncable kind: the review
    // (F3) showed the tokenized twin below goes blind behind a bare regex
    // literal or a raw-string interpolation. This scan reads raw lines and
    // skips only lines whose first non-whitespace is `//` — real code can
    // never live on such a line, and every legitimate doc mention of
    // `AuthClient` does. A future non-`//` mention (a `/* */` block, a log
    // string) fails LOUD and gets reworded.
    const offenders = [WATCH_APP, HEALTH_PLUGIN].flatMap((dir) =>
      swiftFiles(dir).flatMap((path) => {
        const raw = readFileSync(path, "utf8");
        return raw.split("\n").flatMap((line, i) => {
          if (line.trim().startsWith("//")) return [];
          if (!/\b(?:AuthClient|GoTrueClient)\b/.test(line)) return [];
          return [`${path.slice(REPO.length + 1)}:${i + 1}: ${line.trim()}`];
        });
      }),
    );
    expect(offenders).toEqual([]);
  });

  it("never names AuthClient/GoTrueClient in code, anywhere in either directory (tokenized twin)", () => {
    // Kept alongside the raw scan above: this view has no false positives
    // by construction (comments and strings are stripped), so it stays as
    // the precise complement while the raw scan carries the
    // cannot-be-evaded guarantee.
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
