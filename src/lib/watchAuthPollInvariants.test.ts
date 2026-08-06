import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/// Structural guard for issue #472: the watch's slow poll and its two
/// `WCSessionDelegate` callbacks used to decide whether to ask the phone for
/// a fresh token by reading a property derived from `state` — a value set at
/// the *previous* refresh, not recomputed against the clock. Once a relayed
/// token went stale with no external event to react to (nothing else ever
/// changes `state`), every one of these three sites read a
/// permanently-stale "still fresh" answer and never asked again.
///
/// `AuthManager.swift` is watch-app-target code the `quality` job never
/// compiles (only the path-filtered, often-queued `swift` job in
/// `ios-ci.yml` does), and it isn't unit tested even there — `swift test`
/// only runs `SendLogWatchCore`'s pure-logic package, and `AuthManager`
/// itself is not pure logic (WatchConnectivity, timers). So this is a
/// text-scan pin. Verified to fail against the pre-fix source (the poll's
/// `guard let self, self.needsToken else { return }`, and the two delegate
/// callbacks' `if self.needsToken { self.requestSessionFromPhone() }`).
///
/// **Correction (post-review):** an earlier version of this file called
/// itself "the same shape as `nativeAuthInvariants.test.ts`". It wasn't.
/// That file asserts an *absence* of a small, fixed set of API calls across
/// two whole directories, which is genuinely impossible to satisfy by
/// refactoring around it — there is nowhere else to put the call. A version
/// of this file that only inspected four *named* function bodies asserted a
/// *presence* at named sites instead, which an adversarial reviewer showed
/// can be refactored around three different ways while every per-site
/// assertion kept passing: (1) an early `guard needsToken else { return }`
/// at the top of `refreshState()`, hiding behind the one legitimate
/// `SessionRelay.needsToken(...)` call already required in that body; (2) a
/// brand-new fourth decision site elsewhere in the file the per-site checks
/// never look at; (3) a renamed indirection (`var tokenLooksStale: Bool {
/// needsToken }`) consumed by the poll instead of the name the poll's own
/// check forbids. The file-wide test below closes all three at once: after
/// stripping the one legitimate `SessionRelay.needsToken(...)` call, the
/// bare identifier `needsToken` may not appear anywhere in the file, under
/// any name reachable by searching for it — which is why the instance
/// property was also renamed to `needsTokenForDisplay` (see
/// `AuthManager.swift`), leaving no legitimate bare `needsToken` at all.
///
/// **Second correction (post-re-review):** the rename above created a new
/// identifier, and every check here forbade the OLD one with a trailing
/// `\b`, which does not match `needsTokenForDisplay` — so the same reviewer
/// drove all three mutations straight through the pin again by writing them
/// against the name that now exists (`guard needsTokenForDisplay else {
/// return }` etc.). Fixed below: `needsTokenForDisplay` may appear exactly
/// once in this file — its own declaration.
///
/// **What this pin's boundary actually is, stated honestly.** It forbids
/// *this specific* cached read — `state`/`needsTokenForDisplay` — by name,
/// anywhere in the file, under either identifier. It does **not**, and
/// cannot, forbid every conceivable future cache: a `guard case
/// .signedIn(_, true) = self?.state { return }` reads the enum directly
/// without naming either identifier, and a *new* stored flag (e.g.
/// `refreshState()` caching its own `SessionRelay.needsToken(...)` result
/// into a `Bool` the poll then reads) reintroduces the same defect one hop
/// removed, under a name this file cannot know in advance. The direct-enum
/// read is closed below (branch-free auth call sites — reviewer's M4); the
/// as-yet-unnamed-cache case is not, and no text pin can close it — that is
/// the doc contract on `needsTokenForDisplay` and code review's job, not
/// this file's.
///
/// **Third correction (post cross-wave sweep, finding F-B).** Every
/// assertion above pins that the poll and both delegate callbacks *decide*
/// correctly when they run. None of them pinned that the poll *runs at
/// all*. Deleting `startPolling()` from `bootstrap()` — or moving poll
/// ownership elsewhere and dropping that call, e.g. as a "dead code,
/// foreground already refreshes" cleanup — passed every check in this file
/// with the app on screen: the token expires, no foreground event and no
/// reachability change ever fires (both require the phone to do something),
/// and the watch waits forever. That is #472 verbatim, reverted in full,
/// with a fully green pin. Fixed below: `bootstrap()` must call
/// `startPolling()`, and `startPolling()`'s body must contain the actual
/// 20s sleep, not just a call to a function that could itself have been
/// gutted.
///
/// **Fourth correction (post sweep-review, one level deeper each time).**
/// The interval assertion above pins the sleep *duration*, not the *loop* —
/// a poll that fires once is not a poll. Demonstrated: rewrite
/// `startPolling()` as a one-shot debounce (`Task { sleep 20s; guard
/// !cancelled; refreshState() }`, no `while`), or keep the `while` but
/// `break` at the end of its body — both still call `startPolling()` from
/// `bootstrap()`, still contain `Task.sleep(for: .seconds(20))` and
/// `refreshState()`, still have exactly one auth-relevant `guard` — and both
/// passed every assertion above while firing exactly once, 20s after
/// launch, then never again: the token expires 40 minutes into a workout and
/// the watch waits forever, same as before. Fixed below: the loop condition
/// (`while !Task.isCancelled`) must be present and `break` must be absent
/// from the poll body. Also found one level up: nothing pinned that `init()`
/// calls `bootstrap()` at all — `bootstrap()` has exactly one call site, and
/// dropping it (e.g. an incomplete move to a `.task` view modifier) never
/// starts anything, with the same green pin. Fixed below.
///
/// **Where this stops, and why that's not an infinite regress.** Inside this
/// file the causal chain is now finite and pinned end to end: `init →
/// bootstrap → startPolling → while-loop + 20s sleep → refreshState →
/// SessionRelay.needsToken`. The next link *out* is `SendLogWatchApp.swift`
/// constructing `AuthManager()` at all — a different file, out of this pin's
/// scope, and not silently droppable the way everything above was: every
/// view holding `@Environment(AuthManager.self)` would break loudly the
/// moment that line is removed, so it needs no text pin. The link *in* is
/// `requestSessionFromPhone`'s body, addressed below: this file pins that
/// the poll *decides* correctly and that it *exists and actually repeats* —
/// it does not, and does not attempt to, pin that a discovered staleness
/// successfully *sends* anything (`requestSessionFromPhone`'s body is
/// unchecked; neutering it, e.g. making it an unconditional no-op, passes
/// every assertion here). That gap is real and out of this file's stated
/// scope — deciding, not sending — but worth saying plainly rather than
/// leaving a reader to assume coverage that doesn't exist.

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

  it("refreshState() decides via SessionRelay.needsToken, not a cached read", () => {
    const body = bodyAfter(source, /func refreshState\(\)/);
    expect(body).toMatch(/SessionRelay\.needsToken\(for:\s*session,\s*now:\s*now\)/);
    // Strip the one legitimate call *first*, then forbid the bare
    // identifier outright. `not.toMatch(/if\s+needsToken\s*\{/)` alone is
    // one Swift keyword wide — a `guard needsToken else { return }`
    // early-out at the top of this function restores #472 verbatim while
    // still matching that narrower pattern (demonstrated in review).
    expect(body.replace(/SessionRelay\.needsToken\([^)]*\)/g, "")).not.toMatch(/\bneedsToken\b/);
  });

  it("the poll recomputes unconditionally instead of gating on a cached read", () => {
    const body = bodyAfter(source, /private func startPolling\(\)/);
    expect(body).toMatch(/self\??\.refreshState\(\)/);
    expect(body).not.toMatch(/\bneedsToken\b/);
  });

  it("activationDidCompleteWith recomputes before deciding", () => {
    const body = bodyAfter(
      source,
      /activationDidCompleteWith activationState: WCSessionActivationState,\s*error: Error\?\s*\)/,
    );
    expect(body).toMatch(/self\.refreshState\(\)/);
    expect(body).not.toMatch(/\bneedsToken\b/);
    expect(body).not.toMatch(/requestSessionFromPhone\(/);
  });

  it("sessionReachabilityDidChange recomputes before deciding", () => {
    const body = bodyAfter(
      source,
      /func sessionReachabilityDidChange\(_ session: WCSession\)/,
    );
    expect(body).toMatch(/guard session\.isReachable else \{ return \}/);
    expect(body).toMatch(/self\.refreshState\(\)/);
    expect(body).not.toMatch(/\bneedsToken\b/);
    expect(body).not.toMatch(/requestSessionFromPhone\(/);
  });

  it("the bare identifier needsToken appears nowhere in the file outside the one legitimate SessionRelay.needsToken(...) call (#472, post-review)", () => {
    // This is the assertion that actually closes the hole the per-site
    // checks above cannot: those only look inside four *named* function
    // bodies, so (a) a brand-new decision site anywhere else in the file,
    // or (b) a cached property that re-exposes the same boolean under
    // another name and gets consumed from inside a checked body, would
    // pass every check above while reintroducing #472. Demonstrated in
    // review, both surviving all four checks above:
    //   (a) `@MainActor func maybeAskOnWorkoutStart() { if needsToken { requestSessionFromPhone() } }`
    //   (b) `var tokenLooksStale: Bool { needsToken }`, consumed by the
    //       poll as `guard self?.tokenLooksStale == true else { return }`
    //       instead of the name the poll's own check forbids.
    // Stripping the one legitimate `SessionRelay.needsToken(...)` call and
    // then requiring zero remaining bare occurrences of the identifier
    // catches both, plus the refreshState() early-out from the test above,
    // regardless of which function (or none) they sit in. Zero, not "one
    // for its own declaration", because the instance property was renamed
    // to `needsTokenForDisplay` — there is no legitimate bare `needsToken`
    // left in this file at all.
    const withoutLegitimateCalls = source.replace(/SessionRelay\.needsToken\([^)]*\)/g, "");
    const bareOccurrences = withoutLegitimateCalls.match(/\bneedsToken\b/g) ?? [];
    expect(bareOccurrences).toEqual([]);
  });

  it("needsTokenForDisplay appears exactly once in the file — its own declaration (#472, R1)", () => {
    // The zero-bare-`needsToken` check above only forbids the OLD name.
    // `needsTokenForDisplay` (the rename F3 asked for) is `internal`,
    // reachable from anywhere in this target, and deciding from it is
    // exactly as wrong as deciding from `needsToken` was — a
    // `guard needsTokenForDisplay else { return }` early-out at the top of
    // `refreshState()` is #472 verbatim, and the trailing `\b` in the checks
    // above does not match this longer identifier, so that mutation passed
    // every other assertion in this file (demonstrated in re-review). Pin it
    // the same way the old name was pinned: exactly one bare occurrence in
    // the whole file, its own declaration — `HomeView.swift`'s call site is
    // a different file, and every doc-comment mention is already stripped
    // by `code()`.
    const occurrences = source.match(/\bneedsTokenForDisplay\b/g) ?? [];
    expect(occurrences).toHaveLength(1);
  });

  it("[M4] the poll and both delegate callbacks are branch-free with respect to auth (#472)", () => {
    // Closes an escape neither the identifier checks above nor R1 can:
    // reading the cached `WatchAuthState` enum directly —
    // `if case .signedIn(_, true) = self?.state { return }` — reproduces
    // #472 without ever writing `needsToken` or `needsTokenForDisplay`
    // anywhere. These three bodies have exactly one legitimate control-flow
    // guard each (`Task.isCancelled` for the poll, `session.isReachable` for
    // reachability, none for activation) and no reason to ever gain
    // another — any additional `guard`/`if` is, by construction, a new
    // decision this file exists to prevent. (Deliberately brittle: adding
    // any other auth-unrelated branch to these three call sites should force
    // a conscious look at this test, not silently pass.)
    const branchCount = (body: string) => (body.match(/\b(?:guard|if)\b/g) ?? []).length;

    const pollBody = bodyAfter(source, /private func startPolling\(\)/);
    expect(branchCount(pollBody)).toBe(1); // guard !Task.isCancelled else { return }

    const activationBody = bodyAfter(
      source,
      /activationDidCompleteWith activationState: WCSessionActivationState,\s*error: Error\?\s*\)/,
    );
    expect(branchCount(activationBody)).toBe(0);

    const reachabilityBody = bodyAfter(
      source,
      /func sessionReachabilityDidChange\(_ session: WCSession\)/,
    );
    expect(branchCount(reachabilityBody)).toBe(1); // guard session.isReachable else { return }
  });

  it("[F-B] bootstrap() actually starts the poll (#472, cross-wave sweep)", () => {
    // Every other assertion in this file pins that the poll and delegate
    // callbacks decide correctly *when they run*. This one pins that the
    // poll runs at all: deleting `startPolling()` from `bootstrap()` (or
    // moving poll ownership elsewhere and dropping the call, e.g. as a
    // "dead code" cleanup) passed all ten prior assertions while reverting
    // #472 in full — no foreground and no reachability event ever fires
    // while the app just sits on screen, so a token that goes stale mid-
    // session is never rediscovered.
    const bootstrapBody = bodyAfter(source, /func bootstrap\(\)/);
    expect(bootstrapBody).toMatch(/\bstartPolling\(\)/);
  });

  it("[F-B] init() actually starts bootstrap() — the one hop above the assertion just above (#472, sweep-review)", () => {
    // Symmetric with the assertion above, one link further up the chain:
    // `bootstrap()` has exactly one call site. Dropping `Task { @MainActor
    // in bootstrap() }` from `init()` — e.g. an incomplete move to a `.task`
    // view modifier that never actually got wired up — never starts
    // anything, with every other assertion in this file still green.
    const initBody = bodyAfter(source, /override init\(\)/);
    expect(initBody).toMatch(/\bbootstrap\(\)/);
  });

  it("[F-B] startPolling() actually repeats, not a gutted or one-shot stand-in (#472, sweep-review)", () => {
    // Calling `startPolling()` with the sleep interval present still proves
    // nothing if the loop that makes it a *poll* is gone. Demonstrated: a
    // one-shot rewrite (`Task { sleep 20s; guard !cancelled; refreshState()
    // }`, no `while`) and a `while` loop with `break` at the end of its body
    // both still call `startPolling()`, still sleep for the real 20s
    // interval, still call `refreshState()`, still have exactly one
    // auth-relevant guard (the M4 branch-free check above) — and both fire
    // exactly once, 20s after launch, then never again. Pin the loop
    // condition is present and that nothing exits it early.
    const pollBody = bodyAfter(source, /private func startPolling\(\)/);
    expect(pollBody).toMatch(/Task\.sleep\(for:\s*\.seconds\(20\)\)/);
    expect(pollBody).toMatch(/while !Task\.isCancelled/);
    expect(pollBody).not.toMatch(/\bbreak\b/);
  });

  it("the display-only property is not named or documented as a decision predicate (#472)", () => {
    // F3: the old name (`needsToken`) and doc ("True when the watch cannot
    // make an authenticated request right now") read as a general-purpose
    // predicate and invited exactly the misuse #472 was. The rename alone
    // doesn't prove the doc was fixed too, so pin both — against the *raw*
    // file, since `source` above has every comment stripped.
    expect(source).toMatch(/var needsTokenForDisplay: Bool \{/);
    const raw = readFileSync(AUTH_MANAGER_PATH, "utf8");
    const declIndex = raw.indexOf("var needsTokenForDisplay: Bool {");
    expect(declIndex).toBeGreaterThan(-1);
    const docWindow = raw.slice(Math.max(0, declIndex - 900), declIndex);
    expect(docWindow).toMatch(/display only/i);
    expect(docWindow).toMatch(/SessionRelay\.needsToken\(for:now:\)/);
  });
});
