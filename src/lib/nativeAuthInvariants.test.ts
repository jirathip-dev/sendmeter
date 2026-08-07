import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard over code CI cannot otherwise check (issues #265, #266).
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
/// So this asserts the *absence* of the credential and of every SDK call that
/// could rotate one, in the two components that consume the phone's session.
/// It is deliberately a crude text scan.
///
/// **Correction (post-audit, #488 round 1).** This file used to end the
/// paragraph above with "it cannot be satisfied by refactoring around it,
/// only by not doing the thing." That was false, and false in exactly the
/// shape #196 itself failed in: `ROTATING_CALLS` matched fixed dotted chains
/// like `.auth.session` written on one call, so
/// ```swift
/// let authClient = SupabaseService.data.auth   // no ".auth.session" substring
/// let stale = authClient.session                // no ".auth." substring either
/// ```
/// reached the exact #196 accessor one hop removed while every pattern below
/// stayed green — the alias is a different string, so a scan for fixed
/// substrings didn't see it. `watchAuthPollInvariants.test.ts` hit the same
/// class of gap (a per-site/per-pattern scan reachable by indirection) and
/// closed it by forbidding the bare identifier everywhere in its file, not a
/// dotted chain naming one call site. Round 1's fix was the equivalent move:
/// forbid the bare `.auth` property access outright, direct or aliased.
///
/// **Second correction (post-review round 2, #488).** Round 1's new
/// docstring claimed it was "closing the rename/new-file/indirection escapes
/// the per-pattern checks below cannot" — the exact meta-defect #488 is
/// about, repeated in the very sentence describing the fix for it. An
/// adversarial reviewer defeated it two ways:
///
/// - The comment stripper (`swiftCode`/`swiftCodeForAccessorScan` below,
///   `stripComments`/`stripComments`+strings in round 1) used to be
///   `line.replace(/\/\/.*$/, "")` — "delete everything after the first `//`
///   on a line", which also deletes whatever follows a `//` **inside a
///   string literal**. A URL is a `//`-bearing string, and this codebase
///   already has several inside the two guarded directories (e.g.
///   `SupabaseService.swift`'s `URL(string: "http://127.0.0.1:54321")`) — one
///   debug-log line with a URL in it was enough to hide a real
///   `client.auth.session` on the same line from every assertion in this
///   file, old and new. Fixed with a real (if small) tokenizer: `tokenize()`
///   below walks `//` and `/* … */` comments and `"…"`/`"""…"""`/`#"…"#`
///   string literals as distinct segments instead of truncating a line.
/// - The broadened bare-`.auth` scan itself false-positived on legitimate
///   Swift that has nothing to do with `AuthClient`: `case .auth:` in an
///   unrelated enum switch, `forKey: .auth` in a `CodingKeys` decode, a block
///   comment, a triple-quoted string, and — worst of all — a *third* Keychain
///   purge-key literal (the pin going red because someone added *more*
///   correct code was exactly backwards). The consequence is the one that
///   kills pins: the only way to satisfy a false positive is to rename or
///   remove the unrelated code, so the next engineer deletes the pin instead.
///   Fixed by (a) stripping string-literal *contents* too before this
///   specific scan (`swiftCodeForAccessorScan`, used only here — the other
///   checks in this file need to read real string content, e.g. the
///   `"refreshToken"` dictionary key below, so they keep using
///   comment-only-stripped `swiftCode`), and (b) matching **member access**
///   (`AUTH_PROPERTY_ACCESS`: `.auth` immediately preceded by an identifier
///   character, `)`, `]`, or a keypath `\`) instead of any bare `.auth`
///   token — `case .auth:` / `forKey: .auth` / `return .auth` are all
///   *implicit member syntax* referencing an unrelated enum case, always
///   preceded by whitespace or punctuation, never by a receiver.
///
/// Also closed: the scan only ever covered two hardcoded directories, so an
/// accessor helper placed in a third one (e.g. `sendlog-health-core`, already
/// a real dependency of the health plugin) and called with no `.auth` at the
/// call site was invisible. `describe("every Supabase-importing Swift file
/// lives inside a scanned directory …")` below closes that: it asserts the
/// full set of Swift files under `ios/` + `native-plugins/` that `import
/// Supabase` against a short allow-list (the two scanned directories plus one
/// test target that ships nothing), so opening a reachability hole in any
/// other directory goes red immediately instead of silently.
///
/// **Third correction (post-review round 3, #488).** Round 2's tokenizer
/// itself created four new defects in one commit — two of them regressions
/// against round 1 — while fixing what it was asked to fix:
///
/// - **G1 (regression).** `tokenize()` treated Swift string interpolation
///   (`\(…)`) as opaque string content, so `swiftCodeForAccessorScan`
///   blanked it along with everything else — hiding
///   `Logger().debug("token=\(client.auth.session)")`, the exact realistic
///   line the Second Correction above names as the reason this file exists
///   in this shape. Round 1 (plain comment-stripping, strings untouched) saw
///   this line; round 2 didn't. Fixed: a string form with an
///   `interpolationPrefix` re-enters `\(…)` as real code (tracking paren
///   depth, skipping nested string literals wholesale so their parens don't
///   confuse the count) instead of blanking it.
/// - **G2 (regression).** `AUTH_PROPERTY_ACCESS`'s receiver class
///   (`[\w)\]\\]`) didn't include `?`/`!`, so `client?.auth` and
///   `client!.auth` — ordinary optional-chaining/force-unwrap, not evasion —
///   were missed. Round 1's bare `/\.auth\b/` caught both. Fixed: widened to
///   `[\w)\]\\?!}>]` (also picking up `{ … }.auth` and `Foo<Bar>.auth` for
///   free) — verified this doesn't reopen `case .auth:`/`forKey: .auth`,
///   since both are preceded by whitespace either way.
/// - **G3 (new, silent).** A tokenizer that can't find a string's or block
///   comment's closing delimiter (an extended raw string `##"…"##` the old
///   single-`#` form didn't recognize; an escaped `\"""` inside a multi-line
///   string) used to blank the ENTIRE REST OF THE FILE as one giant string
///   segment — no error, no offender, just silently fewer real matches. That
///   is the worst failure mode this file can have: a miss that reads as a
///   pass. Fixed two ways: (a) raw strings now match any hash count
///   generically, and `"""` scanning is escape-aware (`\"""` correctly
///   escapes just the first quote), which removes the two known desync
///   triggers; (b) more importantly, every comment/string form in
///   `tokenize()` now **throws** if it reaches EOF without its terminator,
///   converting every desync mode — including ones not specifically handled
///   by (a) — from "silently green" to "fails with a file and index". A
///   final self-check (the reconstructed segments must equal the input
///   exactly) catches any other way the tokenizer could drop text. Swept all
///   135 Swift files under `ios/` + `native-plugins/` against the new
///   tokenizer: zero desyncs today — this is entirely about future input.
/// - **G4.** The import allow-list (`describe("every Supabase-importing
///   Swift file …")` below) matched only `import Supabase`, but
///   supabase-swift ships `AuthClient` in the separately importable `Auth`
///   product (`PostgREST`/`Realtime`/`Storage`/`Functions` too) — a file
///   could `import Auth`, hold an `AuthClient`, and never write the word
///   "Supabase", reopening the exact reachability hole that assertion exists
///   to close. Fixed: the regex now matches any of the six product names.
/// - **G5 (new, low severity).** Swift permits nested `/* … */`; the old
///   scanner closed at the first `*/`, so a historical note like `/* Outer
///   /* inner */ … client.auth.session … */` had its tail read as code — a
///   false positive (loud, not silent, but still wrong). Fixed: block
///   comments now track nesting depth.
///
/// The pattern across all three rounds is the same: **an overclaim in this
/// very docstring, found by the next round's adversarial review.** G6 named
/// it directly — the round-2 residual list below was honest about the three
/// things it listed, but silently missing G1–G3, which were more realistic
/// than any of them. This round's list is written from the actual round-3
/// findings, not from what the code was intended to cover.
///
/// **What this still does not cover, stated plainly rather than reused as
/// another overclaim:**
/// - **A member-access dot broken across whitespace this scan doesn't
///   tolerate**, e.g. `client.\n    auth` (dot at end of line) or `client\n
///   .auth` (leading-dot continuation) or a stray `client .auth`. All three
///   are valid Swift. The first two contain no `.auth` substring at all
///   (there's a newline between the dot and the name) — closing them needs a
///   real parser, not a bigger regex. The third (a literal space before the
///   dot) IS something the tokenizer could now normalize before matching
///   (round 2's docstring claimed otherwise — that stopped being true the
///   moment a tokenizer existed, per round-3 review G7). The reason it's
///   still open is a **cost decision, not an impossibility**: tolerating
///   whitespace before the dot would make `case .auth:` / `forKey: .auth` /
///   `return .auth` match again (a keyword or label ends in a word character
///   too), reopening the false-positive class G2/round-2 closed, for a
///   formatting shape SwiftFormat/Xcode's defaults never produce. Not worth
///   the added tokenizer complexity for that trade.
/// - **Raw-string interpolation (`\#(…)`, `\##(…)`, …).** `#"…"#`-style raw
///   strings interpolate with a hash-prefixed escape, not `\(…)` — the
///   `interpolationPrefix` mechanism that closes G1 for ordinary and
///   triple-quoted strings isn't wired up for raw strings. Raw strings are
///   unused in the two guarded directories today (verified); a future one
///   containing an interpolated accessor would be blanked as opaque string
///   content, unseen by the accessor scan.
/// - **Reflection/KVC-style access** (`value(forKeyPath:)`) — not realistic
///   against a non-`@objc` Swift type here, and not checked.
/// - **A rotating-credential accessor added under a name with no "auth" in
///   it at all.** This file greps for a name; it cannot know about a future
///   name it has never seen. That is code review's job, same as the
///   precedent (`watchAuthPollInvariants.test.ts`) states for its own
///   equivalent gap.
///
/// **On the pin's complexity itself:** round 3's review assessed ~90 lines of
/// hand-rolled Swift/TS lexing producing four defects in its first round as
/// on the wrong trajectory, and recommended a structural follow-up — making
/// the accessor unreachable by construction (a private `SupabaseClient`
/// behind a small façade per target, collapsing this file's job to two
/// greps) — rather than a fourth round of tokenizer patches. That is tracked
/// as a separate issue, not attempted here.

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
/// missing (#488 G3). A final self-check confirms the segments reconstruct
/// the input exactly. Not a full lexer for either language — good enough for
/// ordinary application source, not text built specifically to evade a scan
/// (see the module doc comment for the residual this still doesn't cover).
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
  const reconstructed = segments.map((s) => s.text).join("");
  if (reconstructed !== src) {
    throw new TokenizeDesyncError("(segments don't reconstruct the source — this is a tokenizer bug, not an input problem)", sourceLabel, 0);
  }
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
/// AuthClient-reachability scans only. A string's content (a URL, a Keychain
/// key name, a doc line quoted in a log message) must never be mistaken for
/// real code touching `.auth`. String INTERPOLATION is the exception —
/// `tokenize()` re-enters `\(…)` as code, so an accessor written inside a
/// string interpolation stays visible here (#488 G1).
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
// chaining/force-unwrap — `client?.auth`, `client!.auth` are ordinary
// idiomatic Swift, #488 G2), `}`/`>` (`{ … }.auth`, `Foo<Bar>.auth`), or a
// keypath backslash — i.e. real member access — NOT preceded by whitespace
// or punctuation, which is how implicit-member syntax referencing an
// unrelated enum case always looks (`case .auth:`, `forKey: .auth`, `return
// .auth`; a keyword/label ends in a word character too, which is what makes
// this narrowing sound — widening the receiver class further doesn't touch
// it, only tolerating whitespace before the dot would). See the module doc
// comment for what this deliberately still doesn't catch.
const AUTH_PROPERTY_ACCESS = /[\w)\]\\?!}>]\.auth\b/g;

describe("no session-consuming native client may hold or spend a refresh token (#265)", () => {
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

  it("never touches AuthClient at all — no `.auth` property access, direct or aliased (#196, #488)", () => {
    // Round 1 forbade bare `.auth` anywhere in the two guarded directories.
    // Round 2 (see the module doc comment) narrowed the match to real member
    // access and moved the string/comment stripping to a proper tokenizer —
    // `consumers` above is already comment-AND-string-stripped
    // (`swiftCodeForAccessorScan`), so there's nothing left to strip here.
    // There is currently zero legitimate use of `.auth` as member access
    // anywhere in either consumer: both clients are built with an
    // `accessToken` closure and never construct or reach an `AuthClient`
    // (see `SupabaseService.swift` / `HealthConfig.swift`).
    const offenders = consumers.flatMap(({ path, scanText }) =>
      [...scanText.matchAll(AUTH_PROPERTY_ACCESS)].map((m) => offenseAt(path, scanText, m.index)),
    );
    expect(offenders).toEqual([]);
  });

  it("configures every Supabase client with a non-refreshing accessToken provider", () => {
    // The seam that makes the above structural rather than incidental: a
    // client built with an `accessToken` provider never consults an
    // AuthClient, so there is no session for the SDK to recover or renew.
    const clients = consumers.filter((s) => /SupabaseClient\s*\(/.test(s.scanText));
    expect(clients.length).toBeGreaterThan(0);
    for (const client of clients) {
      expect(client.scanText, client.path).toMatch(/accessToken:\s*\{/);
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
