import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const REPO = join(import.meta.dirname, "..", "..");
const WATCH_APP = join(REPO, "ios", "App", "SendLogWatch Watch App");
const READINESS_MANAGER = join(WATCH_APP, "Services", "ReadinessManager.swift");
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
    expect(healthSources).toMatch(/\.from\("health_metrics"\)/);
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
});
