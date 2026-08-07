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
/// **What this still does not cover, stated plainly rather than reused as
/// another overclaim:**
/// - **A member-access dot broken across whitespace this scan doesn't
///   tolerate**, e.g. `client.\n    auth` (dot at end of line) or `client\n
///   .auth` (leading-dot continuation) or a stray `client .auth`. All three
///   are valid Swift. The first two contain no `.auth` substring at all
///   (there's a newline between the dot and the name), so no text-substring
///   scan can catch them without a real parser. The third — a literal space
///   before the dot — is deliberately not chased either: allowing arbitrary
///   whitespace before the dot would make `case .auth:` / `forKey: .auth` /
///   `return .auth` match again (a keyword or label ends in a word character
///   too), reopening the exact false-positive class this round just closed.
///   None of these three are realistic — SwiftFormat/Xcode's default
///   formatting never produces them — but they are a real, known gap, not a
///   closed one.
/// - **Reflection/KVC-style access** (`value(forKeyPath:)`) — not realistic
///   against a non-`@objc` Swift type here, and not checked.
/// - **A rotating-credential accessor added under a name with no "auth" in
///   it at all.** This file greps for a name; it cannot know about a future
///   name it has never seen. That is code review's job, same as the
///   precedent (`watchAuthPollInvariants.test.ts`) states for its own
///   equivalent gap.

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
  // `close` — only meaningful (and only needed) for single-character quotes.
  escapes: boolean;
}

/// A small shared tokenizer for `//` / `/* … */` comments plus a
/// caller-supplied list of quoted-string forms (checked in the given order,
/// so put more specific/longer delimiters first — e.g. `"""` before `"`).
/// Not a full lexer for either language: string interpolation (`\(…)` in
/// Swift, `${…}` in TS) is treated as opaque string content, not re-entered
/// as code. That's a real, deliberate simplification (see the module doc
/// comment above) — good enough for ordinary application source, not text
/// built specifically to evade a scan.
function tokenize(src: string, stringForms: StringForm[]): Segment[] {
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
      const end = src.indexOf("*/", i + 2);
      const j = end === -1 ? src.length : end + 2;
      segments.push({ text: src.slice(i, j), kind: "comment" });
      i = j;
      continue;
    }
    for (const form of stringForms) {
      if (src.startsWith(form.open, i)) {
        let j = i + form.open.length;
        while (j < src.length && !src.startsWith(form.close, j)) {
          j += form.escapes && src[j] === "\\" ? 2 : 1;
        }
        j = Math.min(j + form.close.length, src.length);
        segments.push({ text: src.slice(i, j), kind: "string" });
        i = j;
        continue outer;
      }
    }
    let j = i + 1;
    scan: while (j < src.length) {
      if (src.startsWith("//", j) || src.startsWith("/*", j)) break scan;
      for (const form of stringForms) {
        if (src.startsWith(form.open, j)) break scan;
      }
      j++;
    }
    segments.push({ text: src.slice(i, j), kind: "code" });
    i = j;
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
  { open: '"""', close: '"""', escapes: false },
  { open: '#"', close: '"#', escapes: false },
  { open: '"', close: '"', escapes: true },
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
  return tokenize(readFileSync(path, "utf8"), SWIFT_STRINGS)
    .map((s) => (s.kind === "comment" ? blank(s.text) : s.text))
    .join("");
}

/// Comments AND string-literal contents both stripped — for the
/// AuthClient-reachability scans only. A string's content (a URL, a Keychain
/// key name, a doc line quoted in a log message) must never be mistaken for
/// real code touching `.auth`.
function swiftCodeForAccessorScan(path: string): string {
  return tokenize(readFileSync(path, "utf8"), SWIFT_STRINGS)
    .map((s) => (s.kind === "code" ? s.text : blank(s.text)))
    .join("");
}

/// Same idea as `swiftCode`, for the two plain-TS reads below — a `//`
/// inside a string literal used to truncate those the same way (round 1 only
/// fixed the Swift side; this closes the identical shape in this same file).
function tsCodeWithoutComments(path: string): string {
  return tokenize(readFileSync(path, "utf8"), TS_STRINGS)
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

// `.auth` preceded by an identifier character, `)`, `]`, or a keypath
// backslash — i.e. real member access (`client.auth`, `bridge().auth`,
// `arr[0].auth`, `\.auth` as a KeyPath literal) — NOT preceded by whitespace
// or punctuation, which is how implicit-member syntax referencing an
// unrelated enum case always looks (`case .auth:`, `forKey: .auth`, `return
// .auth`). See the module doc comment for what this deliberately still
// doesn't catch.
const AUTH_PROPERTY_ACCESS = /[\w)\]\\]\.auth\b/g;

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
    const importers = [...swiftFiles(IOS_ROOT), ...swiftFiles(NATIVE_PLUGINS_ROOT)].filter((p) =>
      /^\s*import\s+Supabase\b/m.test(readFileSync(p, "utf8")),
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
