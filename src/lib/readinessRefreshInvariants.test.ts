import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const REPO = join(import.meta.dirname, "..", "..");
const WATCH_APP = join(REPO, "ios", "App", "SendLogWatch Watch App");
const READINESS_MANAGER = join(WATCH_APP, "Services", "ReadinessManager.swift");
const AUTH_MANAGER = join(WATCH_APP, "Services", "AuthManager.swift");
const WIDGET_BRIDGE = join(WATCH_APP, "Services", "WidgetBridge.swift");
const HEALTH_PLUGIN = join(
  REPO,
  "native-plugins",
  "sendlog-health",
  "ios",
  "Sources",
  "SendLogHealth",
);
const AUTH_BRIDGE = join(
  REPO,
  "native-plugins",
  "sendlog-auth-bridge",
  "ios",
  "Sources",
  "SendLogAuthBridge",
);
const HEALTH_MANAGER = join(
  REPO,
  "native-plugins",
  "sendlog-health",
  "ios",
  "Sources",
  "SendLogHealth",
  "HealthSyncManager.swift",
);

function swiftFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return swiftFiles(path);
    return path.endsWith(".swift") ? [path] : [];
  });
}

function source(path: string): string {
  return readFileSync(path, "utf8");
}

describe("watch-triggered readiness architecture (#520)", () => {
  it("keeps HealthKit and health_metrics writes phone-only", () => {
    const watchSources = swiftFiles(WATCH_APP).map(source).join("\n");
    // WorkoutManager legitimately owns the watch workout/heart-rate session;
    // the invariant is specifically that readiness never gains a second
    // HealthKit reader or computation path.
    const readinessManager = source(READINESS_MANAGER);
    expect(readinessManager).not.toMatch(/\bimport\s+HealthKit\b/);
    expect(readinessManager).not.toMatch(/\bHK(?:HealthStore|QuantityType|CategoryType)\b/);
    expect(readinessManager).not.toMatch(/RecoveryEngine|HealthKitReader/);
    expect(watchSources).not.toMatch(
      /\.from\(["']health_metrics["']\)[\s\S]{0,120}\.(?:upsert|insert|delete)\s*\(/,
    );

    const healthSources = swiftFiles(HEALTH_PLUGIN).map(source).join("\n");
    expect(healthSources).toMatch(/HealthKitReader/);
    expect(healthSources).toMatch(/\.from\("health_metrics", accessToken: binding\.accessToken\)/);
    expect(healthSources).toMatch(/\.upsert\(/);
  });

  it("stamps every watch request and routes execution through the generic bridge", () => {
    const manager = source(READINESS_MANAGER);
    expect(manager).toMatch(/WatchBuild\.stamp\(request\.message\(\)\)/);
    expect(manager).not.toMatch(/Repo\.fetchLatestHealthMetric/);
    expect(manager).not.toMatch(/HealthKitReader|RecoveryEngine|\.upsert\(/);

    const bridge = swiftFiles(AUTH_BRIDGE).map(source).join("\n");
    expect(bridge).toMatch(/SendLogReadinessBridge\.route/);
    expect(bridge).toMatch(/didReceiveMessage[\s\S]*replyHandler/);
    const phoneColdSeed =
      bridge.match(/override public func load\(\)[\s\S]*?registerResultPublisher/)?.[0] ?? "";
    expect(phoneColdSeed).toMatch(/session\.applicationContext/);
    expect(phoneColdSeed).toMatch(/applicationContext\.reconcile/);
    expect(phoneColdSeed).not.toMatch(/receivedApplicationContext/);
    expect(source(join(AUTH_BRIDGE, "ReadinessBridge.swift"))).not.toMatch(
      /refreshToken/,
    );
  });

  it("keeps the readiness result contract free of credentials", () => {
    const contract = source(
      join(
        REPO,
        "ios",
        "App",
        "SendLogWatchCore",
        "Sources",
        "SendLogWatchCore",
        "ReadinessRefresh.swift",
      ),
    );
    expect(contract).not.toMatch(/accessToken|refreshToken|password/i);
    expect(contract).toMatch(/requestId/);
    expect(contract).toMatch(/startedAt/);
    expect(contract).toMatch(/completedAt/);
    expect(contract).toMatch(/freshness/);
  });

  it("gates native flight/account publication and widget task commits", () => {
    const health = source(HEALTH_MANAGER);
    expect(health).toMatch(/ReadinessTaskGate/);
    expect(health).toMatch(/ReadinessAccountEpoch/);
    expect(health).toMatch(/deliverWatchResult/);
    expect(health).toMatch(/ReadinessRefreshDeliveryGate\.allows/);
    expect(health).toMatch(/flightOwner\.isCurrent\(owner\)/);
    expect(health).toMatch(/flightOwner\.invalidate\(\)/);

    const widgets = source(WIDGET_BRIDGE);
    expect(widgets).toMatch(/refreshTask/);
    expect(widgets).toMatch(/refreshGate\.isCurrent\(owner\)/);
    expect(widgets).toMatch(/WidgetStore\.clear\(\)/);
    expect(widgets).toMatch(/var snap = WidgetStore\.load\(\)/);
    const commit = widgets.match(/private static func commitStatus[\s\S]*?\n {4}}/)?.[0] ?? "";
    expect(commit).toMatch(/await computeACWR\(\)/);
    expect(commit.indexOf("await computeACWR()"), "snapshot must be read after ACWR await").toBeLessThan(
      commit.indexOf("var snap = WidgetStore.load()"),
    );
  });

  it("restores the cold native account and binds every Supabase request", () => {
    const health = source(HEALTH_MANAGER);
    const coldInit = health.match(/private init\(\)[\s\S]*?func requestAuthorization/)?.[0] ?? "";
    expect(coldInit).toMatch(/HealthSessionStore\.shared\.accessToken/);
    expect(coldInit).toMatch(/AccessTokenClaims\(jwt: persisted\)/);
    expect(coldInit).toMatch(/accountEpoch\.restoreSession/);
    expect(coldInit).toMatch(/HealthSessionStore\.shared\.isSignedOut/);
    expect(health).toMatch(/HealthSessionBinding/);
    expect(health).toMatch(/requestedBinding: HealthSessionBinding\?/);
    expect(health).toMatch(/\.from\("health_metrics", accessToken: binding\.accessToken\)/);
    expect(health).toMatch(/\.from\("sessions", accessToken: binding\.accessToken\)/);

    const setSession = health.match(/func setSession\(accessToken: String\)[\s\S]*?\n {4}}/)?.[0] ?? "";
    expect(setSession.indexOf("invalidateFlight()"), "old flight must be invalidated before bearer exposure").toBeGreaterThanOrEqual(0);
    expect(setSession.indexOf("invalidateFlight()"), "old flight must be invalidated before bearer exposure").toBeLessThan(
      setSession.indexOf("HealthSessionStore.shared.store(accessToken)"),
    );
    expect(setSession).toMatch(/clearRequestState\(\)/);
    expect(health).toMatch(/accountUserId: accountUserId/);
    expect(health).toMatch(/accountUserId: binding\?\.identity\.userId/);
  });

  it("binds watch results to the accepted account before timestamp coalescing", () => {
    const contract = source(
      join(
        REPO,
        "ios",
        "App",
        "SendLogWatchCore",
        "Sources",
        "SendLogWatchCore",
        "ReadinessRefresh.swift",
      ),
    );
    const manager = source(READINESS_MANAGER);
    expect(contract).toMatch(/accountUserId/);
    expect(contract).toMatch(/activeRequestAccountUserId/);
    expect(contract).toMatch(/activeRequestId, activeRequestId != result.requestId/);
    expect(manager).toMatch(/currentAccountUserId: currentAccountUserId/);
    expect(manager).toMatch(/activeRequestAccountUserId: activeRequestAccountUserId/);
    expect(manager).toMatch(/lastAppliedAccountUserId: lastAppliedAccountUserId/);
  });

  it("never re-enters sessionLock through the account-ownership helper", () => {
    const health = source(HEALTH_MANAGER);
    const handle = health.match(
      /private func handleWatchRequest[\s\S]*?private func deliverWatchResult/,
    )?.[0] ?? "";
    expect(handle).toMatch(/let result = await task\.value/);
    expect(handle).toMatch(
      /let result = await task\.value[\s\S]*?guard ownsAccount\(requestIdentity\)/,
    );
    expect(handle).toMatch(
      /sessionLock\.lock\(\)[\s\S]*?guard ownsAccountLocked\(requestIdentity\)/,
    );
    expect(handle).not.toMatch(
      /sessionLock\.lock\(\)[\s\S]*?guard ownsAccount\(requestIdentity\)/,
    );
    expect(health).toMatch(/private func ownsAccountLocked\(/);
  });

  it("closes readiness and widget publication at local sign-out", () => {
    const manager = source(READINESS_MANAGER);
    const signOut = manager.match(/func signOutLocally\([^)]*\)[\s\S]*?\n {4}}/)?.[0] ?? "";
    expect(signOut).toMatch(/acceptsResults = false/);
    expect(signOut).toMatch(/snapshot = WidgetSnapshot\.empty/);
    expect(signOut).toMatch(/result = nil/);
    expect(signOut).toMatch(/lastResultAt = nil/);
    expect(signOut).toMatch(/WidgetStore\.clear\(\)/);
    expect(signOut).toMatch(/WidgetBridge\.invalidate\(\)/);
    expect(signOut).toMatch(/if let outgoingAccountUserId/);
    expect(signOut).toMatch(/lastAppliedAccountUserId = outgoingAccountUserId/);
    expect(manager).toMatch(/guard let currentAccountUserId[\s\S]*?acceptsResults/);

    const auth = source(AUTH_MANAGER);
    const apply = auth.match(/private func apply\(_ context: \[String: Any\]\)[\s\S]*?\n {4}}/)?.[0] ?? "";
    const signedOut = apply.match(/case \.signedOut:[\s\S]*?Self\.log\.info\("relay: phone signed out"\)/)?.[0] ?? "";
    const capture = signedOut.indexOf("let outgoingAccountUserId = WatchSessionStore.shared.userId");
    expect(capture).toBeGreaterThanOrEqual(0);
    expect(capture).toBeLessThan(signedOut.indexOf("signOutLocally()"));
    expect(signedOut).toMatch(/signOutLocally\(\s*outgoingAccountUserId: outgoingAccountUserId/);
  });

  it("resets the B timestamp baseline after an account transition", () => {
    const manager = source(READINESS_MANAGER);
    const receive = manager.match(/func receive\(_ result: ReadinessRefreshResult\)[\s\S]*?\n {4}}/)?.[0] ?? "";
    expect(receive).toMatch(/if lastAppliedAccountUserId == currentAccountUserId/);
    expect(receive).toMatch(/lastAppliedCompletedAt = result\.completedAt/);
    expect(receive).toMatch(/lastAppliedAccountUserId = currentAccountUserId/);
  });

  it("validates a combined auth/readiness context before opening the result gate", () => {
    const auth = source(AUTH_MANAGER);
    const apply = auth.match(/private func apply\(_ context: \[String: Any\]\)[\s\S]*?\n {4}}/)?.[0] ?? "";
    expect(apply.indexOf("SessionRelay.decode"), "auth must decode before readiness publication").toBeGreaterThanOrEqual(0);
    expect(apply.indexOf("SessionRelay.decode"), "auth must decode before readiness publication").toBeLessThan(
      apply.indexOf("activateForSignedInSession()"),
    );
    expect(apply).toMatch(/if reason == \.notARelay/);
  });

  it("fences A before opening B readiness on a direct signedIn switch", () => {
    const auth = source(AUTH_MANAGER);
    const apply = auth.match(/private func apply\(_ context: \[String: Any\]\)[\s\S]*?\n {4}}/)?.[0] ?? "";
    const priorUser = apply.indexOf("WatchSessionStore.shared.userId");
    const reset = apply.indexOf("resetForAccountTransition()");
    const store = apply.indexOf("WatchSessionStore.shared.store(session)");
    const activate = apply.indexOf("activateForSignedInSession()");
    const receive = apply.indexOf("ReadinessManager.current?.receive(context)");
    expect(priorUser).toBeGreaterThanOrEqual(0);
    expect(reset).toBeGreaterThan(priorUser);
    expect(store).toBeGreaterThan(reset);
    expect(activate).toBeGreaterThan(store);
    expect(receive).toBeGreaterThan(activate);
    expect(source(READINESS_MANAGER)).toMatch(/func resetForAccountTransition\(\)/);
  });

  it("flushes a durable, fresh-stamped signedOut context after WC activation", () => {
    const bridge = source(join(AUTH_BRIDGE, "Plugin.swift"));
    const activation = bridge.match(
      /activationDidCompleteWith activationState:[\s\S]*?public func sessionDidBecomeInactive/,
    )?.[0] ?? "";
    expect(activation).toMatch(/activationState == \.activated/);
    expect(bridge).toMatch(/signedOutKey/);
    expect(activation).toMatch(
      /relay\(\s*\["event": "signedOut"\][\s\S]*?guaranteed: true[\s\S]*?requireSignedOut: true/,
    );
    expect(bridge).toMatch(/stampedPayload\["relayId"\] = UUID\(\)\.uuidString/);
    expect(bridge).toMatch(/stampedPayload\["relayedAt"\] = Date\(\)\.timeIntervalSince1970/);
  });

  it("linearizes signedOut before readiness direct publication", () => {
    const bridge = source(join(AUTH_BRIDGE, "Plugin.swift"));
    const clear = bridge.match(/@objc func clearSession[\s\S]*?call\.resolve\(\)/)?.[0] ?? "";
    expect(clear).toMatch(/relay\(\["event": "signedOut"\]\)/);
    expect(clear).not.toMatch(/applicationContext\s*=\s*ReadinessApplicationContext/);
    const relay = bridge.match(/private func relay\([\s\S]*?\n {4}}/)?.[0] ?? "";
    expect(relay).toMatch(/!signedOut/);
    expect(relay).toMatch(/applicationContext\.update\(context\)/);
    expect(bridge).toMatch(/signedOutKey/);
    expect(bridge).toMatch(/UserDefaults\.standard\.bool\(forKey: signedOutKey\)/);
  });
});
