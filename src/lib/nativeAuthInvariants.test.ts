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
/// **Correction (post-audit, #488).** This file used to end the paragraph
/// above with "it cannot be satisfied by refactoring around it, only by not
/// doing the thing." That was false, and false in exactly the shape #196
/// itself failed in: `ROTATING_CALLS` matches fixed dotted chains like
/// `.auth.session` written on one call, so
/// ```swift
/// let authClient = SupabaseService.data.auth   // no ".auth.session" substring
/// let stale = authClient.session                // no ".auth." substring either
/// ```
/// reaches the exact #196 accessor one hop removed while every pattern below
/// stays green — the alias is a different string, so a scan for fixed
/// substrings doesn't see it. `watchAuthPollInvariants.test.ts` hit the same
/// class of gap (a per-site/per-pattern scan reachable by indirection) and
/// closed it by forbidding the bare identifier everywhere in its file, not a
/// dotted chain naming one call site. The equivalent move here is the test
/// below: neither client has any legitimate reason to touch `.auth` at
/// all — both are built with an `accessToken` closure and never construct or
/// reach an `AuthClient` (see `SupabaseService.swift` / `HealthConfig.swift`)
/// — so it forbids the bare `.auth` property access outright, direct or
/// aliased, closing the rename/new-file/indirection escapes the per-pattern
/// checks below cannot.

const REPO = join(import.meta.dirname, "..", "..");

const WATCH_APP = join(REPO, "ios", "App", "SendLogWatch Watch App");
const HEALTH_PLUGIN = join(
  REPO, "native-plugins", "sendlog-health", "ios", "Sources", "SendLogHealth",
);
const AUTH_BRIDGE = join(
  REPO, "native-plugins", "sendlog-auth-bridge", "ios", "Sources", "SendLogAuthBridge",
);

function swiftFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return swiftFiles(path);
    return path.endsWith(".swift") ? [path] : [];
  });
}

/// Strips `//` comments — the prose in these files necessarily *discusses*
/// refresh tokens, and the point is that no code touches one.
function code(path: string): string {
  return readFileSync(path, "utf8")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

function sources(...dirs: string[]): { path: string; code: string }[] {
  return dirs.flatMap((dir) =>
    swiftFiles(dir).map((path) => ({
      path: path.slice(REPO.length + 1),
      code: code(path),
    })),
  );
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

describe("no session-consuming native client may hold or spend a refresh token (#265)", () => {
  const consumers = sources(WATCH_APP, HEALTH_PLUGIN);

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
      const offenders = consumers
        .filter((s) => pattern.test(s.code))
        .map((s) => s.path);
      expect(offenders).toEqual([]);
    });
  }

  it("never touches AuthClient at all — no `.auth` property access, direct or aliased (#196, #488)", () => {
    // The checks above only match specific dotted chains (`.auth.session`,
    // `.auth.setSession(`, ...) written out on one call. #196's accessor
    // survives an alias: `let a = client.auth` then `a.session` contains
    // none of those substrings. There is currently zero legitimate use of
    // `.auth` anywhere in either consumer — grep the two source directories
    // and the only two hits are the Keychain service-key string literals
    // `"supabase.auth.token"` / `"supabase.auth.token-code-verifier"`, which
    // this strips before matching. Everything else is a real access to
    // `AuthClient`, so ANY remaining `.auth` — under any local name, in any
    // file in these directories, new or existing — is the #196 accessor
    // reached one hop removed.
    const offenders = consumers.flatMap(({ path, code }) => {
      const withoutKeychainKeyLiterals = code.replace(
        /"supabase\.auth\.token(?:-code-verifier)?"/g,
        "",
      );
      return /\.auth\b/.test(withoutKeychainKeyLiterals) ? [path] : [];
    });
    expect(offenders).toEqual([]);
  });

  it("configures every Supabase client with a non-refreshing accessToken provider", () => {
    // The seam that makes the above structural rather than incidental: a
    // client built with an `accessToken` provider never consults an
    // AuthClient, so there is no session for the SDK to recover or renew.
    const clients = consumers.filter((s) => /SupabaseClient\s*\(/.test(s.code));
    expect(clients.length).toBeGreaterThan(0);
    for (const client of clients) {
      expect(client.code, client.path).toMatch(/accessToken:\s*\{/);
    }
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
      const src = readFileSync(join(REPO, "src", "lib", file), "utf8")
        .split("\n")
        .map((line) => line.replace(/\/\/.*$/, ""))
        .join("\n");
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
