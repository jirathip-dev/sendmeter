import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard for issue #472: the watch's slow poll and its two
/// `WCSessionDelegate` callbacks used to decide whether to ask the phone for
/// a fresh token by reading `needsToken`, a property derived from `state` —
/// a value set at the *previous* refresh, not recomputed against the clock.
/// Once a relayed token went stale with no external event to react to
/// (nothing else ever changes `state`), every one of these three sites read
/// a permanently-stale "still fresh" answer and never asked again.
///
/// `AuthManager.swift` is watch-app-target code the `quality` job never
/// compiles (only the path-filtered, often-queued `swift` job in
/// `ios-ci.yml` does), and it isn't unit tested even there — `swift test`
/// only runs `SendLogWatchCore`'s pure-logic package, and `AuthManager`
/// itself is not pure logic (WatchConnectivity, timers). So this is a
/// text-scan pin, the same shape as `nativeAuthInvariants.test.ts`: it can't
/// be satisfied by a correct pure helper sitting unused beside the old
/// cached-read guard — only by routing the three production call sites
/// through it. Verified to fail against the pre-fix source (the poll's
/// `guard let self, self.needsToken else { return }`, and the two delegate
/// callbacks' `if self.needsToken { self.requestSessionFromPhone() }`).

const REPO = join(import.meta.dirname, "..", "..");
const AUTH_MANAGER_PATH = join(
  REPO,
  "ios",
  "App",
  "SendLogWatch Watch App",
  "Services",
  "AuthManager.swift",
);
const SESSION_RELAY_PATH = join(
  REPO,
  "ios",
  "App",
  "SendLogWatchCore",
  "Sources",
  "SendLogWatchCore",
  "SessionRelay.swift",
);

function code(path: string): string {
  return readFileSync(path, "utf8")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

/// Extracts the brace-delimited body of the first function/closure whose
/// signature matches `signature`, by counting braces from the first `{`
/// after the match rather than matching a line-shaped regex — so
/// reformatting the body (wrapping a line, adding a blank line) doesn't
/// silently break the test.
function bodyAfter(source: string, signature: RegExp): string {
  const m = signature.exec(source);
  if (!m) throw new Error(`signature not found: ${signature}`);
  const openBrace = source.indexOf("{", m.index + m[0].length);
  if (openBrace === -1) throw new Error(`no opening brace after: ${signature}`);
  let depth = 0;
  for (let i = openBrace; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}") {
      depth--;
      if (depth === 0) return source.slice(openBrace, i + 1);
    }
  }
  throw new Error(`unbalanced braces after: ${signature}`);
}

const source = code(AUTH_MANAGER_PATH);

describe("AuthManager routes token-staleness decisions through the clock, not a cache (#472)", () => {
  it("finds the file it's supposed to be guarding", () => {
    // A path typo would turn every assertion below into a vacuous pass.
    expect(source.length).toBeGreaterThan(1000);
    expect(source).toMatch(/final class AuthManager/);
  });

  it("SendLogWatchCore exposes the pure, clock-derived decision", () => {
    const relaySource = code(SESSION_RELAY_PATH);
    expect(relaySource).toMatch(
      /static func needsToken\(for session: RelayedSession\?, now: TimeInterval\) -> Bool/,
    );
  });

  it("refreshState() decides via SessionRelay.needsToken, not the cached instance property", () => {
    const body = bodyAfter(source, /func refreshState\(\)/);
    expect(body).toMatch(/SessionRelay\.needsToken\(for:\s*session,\s*now:\s*now\)/);
    expect(body).not.toMatch(/if\s+needsToken\s*\{/);
  });

  it("the poll recomputes unconditionally instead of gating on cached needsToken", () => {
    const body = bodyAfter(source, /private func startPolling\(\)/);
    expect(body).toMatch(/self\??\.refreshState\(\)/);
    expect(body).not.toMatch(/needsToken/);
  });

  it("activationDidCompleteWith recomputes before deciding", () => {
    const body = bodyAfter(
      source,
      /activationDidCompleteWith activationState: WCSessionActivationState,\s*error: Error\?\s*\)/,
    );
    expect(body).toMatch(/self\.refreshState\(\)/);
    expect(body).not.toMatch(/needsToken/);
    expect(body).not.toMatch(/requestSessionFromPhone\(/);
  });

  it("sessionReachabilityDidChange recomputes before deciding", () => {
    const body = bodyAfter(
      source,
      /func sessionReachabilityDidChange\(_ session: WCSession\)/,
    );
    expect(body).toMatch(/guard session\.isReachable else \{ return \}/);
    expect(body).toMatch(/self\.refreshState\(\)/);
    expect(body).not.toMatch(/needsToken/);
    expect(body).not.toMatch(/requestSessionFromPhone\(/);
  });
});
