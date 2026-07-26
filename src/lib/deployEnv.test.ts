import { describe, it, expect } from "vitest";
import { DEFAULT_DEPLOY_ENV, resolveDeployEnv } from "./deployEnv";

describe("resolveDeployEnv", () => {
  it("falls back to local when nothing is set", () => {
    expect(resolveDeployEnv({})).toBe("local");
    expect(resolveDeployEnv()).toBe(DEFAULT_DEPLOY_ENV);
  });

  it("uses VERCEL_ENV when that is all there is", () => {
    expect(resolveDeployEnv({ VERCEL_ENV: "production" })).toBe("production");
    expect(resolveDeployEnv({ VERCEL_ENV: "preview" })).toBe("preview");
    expect(resolveDeployEnv({ VERCEL_ENV: "development" })).toBe("development");
  });

  it("uses the explicit override when there is no VERCEL_ENV (TestFlight)", () => {
    expect(resolveDeployEnv({ VITE_DEPLOY_ENV: "ios" })).toBe("ios");
  });

  // The order that matters: Vercel always sets VERCEL_ENV, so an override that
  // lost to it would be unusable on the one platform you'd override from.
  it("prefers the explicit override over VERCEL_ENV", () => {
    expect(
      resolveDeployEnv({ VITE_DEPLOY_ENV: "ios", VERCEL_ENV: "production" }),
    ).toBe("ios");
  });

  it("pins the full precedence chain", () => {
    const vercel = "preview";
    const override = "ios";
    expect(resolveDeployEnv({ VITE_DEPLOY_ENV: override, VERCEL_ENV: vercel })).toBe(
      override,
    );
    expect(resolveDeployEnv({ VERCEL_ENV: vercel })).toBe(vercel);
    expect(resolveDeployEnv({})).toBe(DEFAULT_DEPLOY_ENV);
  });

  it("treats blank and whitespace-only values as unset", () => {
    expect(resolveDeployEnv({ VITE_DEPLOY_ENV: "", VERCEL_ENV: "preview" })).toBe(
      "preview",
    );
    expect(resolveDeployEnv({ VITE_DEPLOY_ENV: "   ", VERCEL_ENV: "preview" })).toBe(
      "preview",
    );
    expect(resolveDeployEnv({ VITE_DEPLOY_ENV: "", VERCEL_ENV: "" })).toBe("local");
  });

  it("trims surrounding whitespace off a value it does use", () => {
    expect(resolveDeployEnv({ VERCEL_ENV: " production\n" })).toBe("production");
  });

  it("accepts a real process.env-shaped object", () => {
    const env: Record<string, string | undefined> = {
      PATH: "/usr/bin",
      VERCEL_ENV: "preview",
    };
    expect(resolveDeployEnv(env)).toBe("preview");
  });
});
