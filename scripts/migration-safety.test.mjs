import { describe, expect, it, vi } from "vitest";
import {
  checkoutFreshness,
  checkoutGuardExitCode,
  formatLedgerOnlyWarning,
  ledgerNamesWithoutLocalFiles,
  localMigrationsRecordedMessage,
} from "./migration-safety.mjs";

function gitRunner({ behind = 0, fetchStatus = 0 } = {}) {
  const calls = [];
  const run = vi.fn((args) => {
    calls.push(args);
    const command = args[0];
    if (command === "rev-parse") return { status: 0, stdout: "true\n", stderr: "" };
    if (command === "symbolic-ref") {
      return { status: 0, stdout: "staging\n", stderr: "" };
    }
    if (command === "for-each-ref") {
      return { status: 0, stdout: "origin/staging\n", stderr: "" };
    }
    if (command === "fetch") {
      return {
        status: fetchStatus,
        stdout: "",
        stderr: fetchStatus ? "network unavailable" : "",
      };
    }
    if (command === "rev-list") {
      return { status: 0, stdout: `${behind}\n`, stderr: "" };
    }
    throw new Error(`unexpected git command: ${args.join(" ")}`);
  });
  return { run, calls };
}

describe("migration checkout freshness guard (#337)", () => {
  it("refreshes the configured upstream before declaring a checkout current", () => {
    const { run, calls } = gitRunner();
    const error = vi.fn();

    const freshness = checkoutFreshness("/repo", run);
    expect(freshness).toEqual({
      kind: "current",
      upstream: "origin/staging",
    });
    expect(checkoutGuardExitCode(freshness, "migration verification", error)).toBe(0);
    expect(error).not.toHaveBeenCalled();
    expect(calls.findIndex(([command]) => command === "fetch")).toBeLessThan(
      calls.findIndex(([command]) => command === "rev-list"),
    );
  });

  it("returns a nonzero guard code and names unseen commits for a stale checkout", () => {
    const { run } = gitRunner({ behind: 3 });
    const freshness = checkoutFreshness("/repo", run);
    const errors = [];

    expect(checkoutGuardExitCode(freshness, "migration verification", (line) => errors.push(line)))
      .toBe(1);
    expect(errors.join("\n")).toContain("STALE CHECKOUT");
    expect(errors.join("\n")).toContain("3 commits behind origin/staging");
    expect(errors.join("\n")).toContain("Unpulled migrations cannot be seen");
  });

  it("fails closed when a configured upstream cannot be refreshed", () => {
    const { run } = gitRunner({ fetchStatus: 1 });
    const freshness = checkoutFreshness("/repo", run);

    expect(freshness).toEqual({
      kind: "error",
      upstream: "origin/staging",
      detail: "network unavailable",
    });
    expect(checkoutGuardExitCode(freshness, "migration verification", vi.fn())).toBe(1);
  });

  it("keeps the existing path for a branch with no configured upstream", () => {
    const { run } = gitRunner();
    run.mockImplementation((args) => {
      if (args[0] === "rev-parse") return { status: 0, stdout: "true\n", stderr: "" };
      if (args[0] === "symbolic-ref") {
        return { status: 0, stdout: "local-branch\n", stderr: "" };
      }
      if (args[0] === "for-each-ref") return { status: 0, stdout: "", stderr: "" };
      throw new Error(`unexpected git command: ${args.join(" ")}`);
    });
    const freshness = checkoutFreshness("/repo", run);
    const error = vi.fn();

    expect(freshness).toEqual({ kind: "unchecked" });
    expect(checkoutGuardExitCode(freshness, "migration verification", error)).toBe(0);
    expect(error).not.toHaveBeenCalled();
  });

  it("keeps the existing path for a detached CI checkout", () => {
    const { run } = gitRunner();
    run.mockImplementation((args) => {
      if (args[0] === "rev-parse") return { status: 0, stdout: "true\n", stderr: "" };
      if (args[0] === "symbolic-ref") {
        return { status: 1, stdout: "", stderr: "" };
      }
      throw new Error(`unexpected git command: ${args.join(" ")}`);
    });
    const freshness = checkoutFreshness("/repo", run);

    expect(freshness).toEqual({ kind: "unchecked" });
    expect(checkoutGuardExitCode(freshness, "migration verification", vi.fn())).toBe(0);
  });
});

describe("migration comparison messages (#337)", () => {
  const local = [{ name: "create_sessions" }, { name: "add_health_metrics" }];

  it("promotes ledger entries without files into a named warning", () => {
    const names = ledgerNamesWithoutLocalFiles(local, [
      "create_sessions",
      "warmup_presets",
      "rename_warmup_presets_to_routine_presets",
    ]);
    const warning = formatLedgerOnlyWarning([{ label: "prod", names }]);

    expect(warning).toMatch(/^\u26a0 WARNING:/);
    expect(warning).toContain("2 ledger entries have no local migration file");
    expect(warning).toContain("prod (2):");
    expect(warning).toContain("warmup_presets");
    expect(warning).toContain("rename_warmup_presets_to_routine_presets");
    expect(warning).toContain("cannot verify those migrations");
  });

  it("stays quiet when every ledger entry has a local file", () => {
    const names = ledgerNamesWithoutLocalFiles(local, ["create_sessions"]);
    expect(formatLedgerOnlyWarning([{ label: "dev", names }])).toBeNull();
  });

  it("scopes success to the local migrations actually compared", () => {
    expect(localMigrationsRecordedMessage(28, "prod")).toBe(
      "✓ all 28 local migrations are recorded on prod.",
    );
    expect(localMigrationsRecordedMessage(28, "both projects")).toBe(
      "✓ all 28 local migrations are recorded on both projects.",
    );
  });
});
