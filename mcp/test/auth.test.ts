/// Session bootstrap tests: credential precedence (env token > session file
/// > email/password), refresh-on-expiry, dead-credential cleanup, file
/// permissions, and the PKCE password/refresh calls against a recorded
/// fetch. All in tmp dirs; no real network, no real credentials.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  clearStoredSession,
  createAuthClient,
  defaultSessionFilePath,
  loadStoredSession,
  resolveSession,
  saveStoredSession,
  type AuthClient,
} from "../src/auth.js";

const tmpDirs: string[] = [];

function tmpSessionFile(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sendmeter-mcp-test-"));
  tmpDirs.push(dir);
  return path.join(dir, "session.json");
}

afterEach(() => {
  for (const dir of tmpDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function baseConfig(overrides: Record<string, string | null> = {}) {
  return {
    supabaseUrl: "https://example.supabase.co",
    supabaseAnonKey: "anon-key",
    accessToken: null,
    email: null,
    password: null,
    sessionFile: null,
    ...overrides,
  };
}

function fakeAuth(): AuthClient & { refreshCalls: string[]; logins: [string, string][] } {
  const calls: { refreshCalls: string[]; logins: [string, string][] } = {
    refreshCalls: [],
    logins: [],
  };
  return {
    ...calls,
    async signInPassword(email, password) {
      calls.logins.push([email, password]);
      return { accessToken: `at-${email}`, refreshToken: "rt-new", expiresAt: 9999999999, email };
    },
    async refresh(refreshToken) {
      calls.refreshCalls.push(refreshToken);
      return { accessToken: "at-refreshed", refreshToken: "rt-refreshed", expiresAt: 9999999999, email: "dev@test" };
    },
  } as never;
}

describe("resolveSession", () => {
  it("prefers the env token and never touches disk", async () => {
    const file = tmpSessionFile();
    fs.writeFileSync(file, "corrupt");
    const out = await resolveSession({
      config: baseConfig({ accessToken: "env-token" }),
      auth: fakeAuth(),
      sessionFile: file,
    });
    expect(out).toEqual({ accessToken: "env-token", email: null, origin: "env-token" });
    expect(fs.readFileSync(file, "utf8")).toBe("corrupt");
  });

  it("uses a valid stored session as-is", async () => {
    const file = tmpSessionFile();
    saveStoredSession(file, {
      accessToken: "at-stored",
      refreshToken: "rt-stored",
      expiresAt: Math.floor(Date.now() / 1000) + 3600,
      email: "dev@test",
    });
    const out = await resolveSession({ config: baseConfig(), auth: fakeAuth(), sessionFile: file });
    expect(out).toEqual({ accessToken: "at-stored", email: "dev@test", origin: "session-file" });
  });

  it("refreshes an expired stored session and rewrites the file", async () => {
    const file = tmpSessionFile();
    const expired = {
      accessToken: "at-old",
      refreshToken: "rt-old",
      expiresAt: Math.floor(Date.now() / 1000) - 60,
      email: "dev@test",
    };
    saveStoredSession(file, expired);
    const auth = fakeAuth();
    const out = await resolveSession({ config: baseConfig(), auth, sessionFile: file });
    expect(auth.refreshCalls).toEqual(["rt-old"]);
    expect(out.accessToken).toBe("at-refreshed");
    expect(out.origin).toBe("session-file");
    expect(loadStoredSession(file)!.refreshToken).toBe("rt-refreshed");
  });

  it("clears a dead stored session and falls back to env credentials", async () => {
    const file = tmpSessionFile();
    saveStoredSession(file, {
      accessToken: "at-dead",
      refreshToken: "rt-dead",
      expiresAt: Math.floor(Date.now() / 1000) - 60,
      email: "dev@test",
    });
    const auth = fakeAuth();
    auth.refresh = async () => {
      throw new Error("invalid refresh token");
    };
    const out = await resolveSession({
      config: baseConfig({ email: "dev@sendmeter.test", password: "devpassword" }),
      auth,
      sessionFile: file,
    });
    expect(out.origin).toBe("login");
    expect(out.accessToken).toBe("at-dev@sendmeter.test");
    expect(fs.existsSync(file)).toBe(true); // rewritten by the login
    expect(loadStoredSession(file)!.refreshToken).toBe("rt-new");
  });

  it("fails with instructions when nothing is available", async () => {
    const file = tmpSessionFile();
    await expect(
      resolveSession({ config: baseConfig(), auth: fakeAuth(), sessionFile: file }),
    ).rejects.toThrow(/SENDMETER_MCP_TOKEN/);
  });

  it("uses the interactive prompt when provided and no env credentials exist", async () => {
    const file = tmpSessionFile();
    const out = await resolveSession({
      config: baseConfig(),
      auth: fakeAuth(),
      sessionFile: file,
      prompt: async () => "dev@sendmeter.test",
    });
    expect(out.origin).toBe("login");
    expect(out.email).toBe("dev@sendmeter.test");
  });
});

describe("session file", () => {
  it("is written 0600 and survives a round trip", () => {
    const file = tmpSessionFile();
    const session = {
      accessToken: "at",
      refreshToken: "rt",
      expiresAt: 123,
      email: "dev@test",
    };
    saveStoredSession(file, session);
    const mode = fs.statSync(file).mode & 0o777;
    expect(mode).toBe(0o600);
    expect(loadStoredSession(file)).toEqual(session);
    expect(loadStoredSession(path.join(tmpSessionFile(), "nope", "x.json"))).toBeNull();
  });

  it("ignores corrupt content", () => {
    const file = tmpSessionFile();
    fs.writeFileSync(file, "not json");
    expect(loadStoredSession(file)).toBeNull();
    fs.writeFileSync(file, JSON.stringify({ accessToken: "only" }));
    expect(loadStoredSession(file)).toBeNull();
  });

  it("clearStoredSession removes the file and tolerates absence", () => {
    const file = tmpSessionFile();
    saveStoredSession(file, { accessToken: "a", refreshToken: "r", expiresAt: 1, email: "e" });
    clearStoredSession(file);
    expect(fs.existsSync(file)).toBe(false);
    clearStoredSession(file); // no throw
  });

  it("defaultSessionFilePath honours the env override", () => {
    const env = { SENDMETER_MCP_SESSION_FILE: "/tmp/custom-session.json" };
    expect(defaultSessionFilePath(env as NodeJS.ProcessEnv)).toBe("/tmp/custom-session.json");
  });
});

describe("createAuthClient", () => {
  it("signs in via PKCE password grant (POST /auth/v1/token, no refresh stored anywhere else)", async () => {
    const calls: { method: string; url: string; body: string }[] = [];
    const client = createAuthClient("https://example.supabase.co", "anon-key", (async (input, init) => {
      const url = typeof input === "string" ? input : input.url;
      const method = init?.method ?? (typeof input === "string" ? "GET" : input.method);
      const body = init?.body ? String(init.body) : "";
      calls.push({ method, url, body });
      return new Response(
        JSON.stringify({
          access_token: "at-pkce",
          refresh_token: "rt-pkce",
          expires_in: 3600,
          token_type: "bearer",
          user: { email: "dev@sendmeter.test", id: "11111111-1111-1111-1111-111111111111" },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }) as typeof fetch);

    const result = await client.signInPassword("dev@sendmeter.test", "devpassword");
    expect(result.accessToken).toBe("at-pkce");
    expect(result.refreshToken).toBe("rt-pkce");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe("POST");
    expect(calls[0]!.url).toBe("https://example.supabase.co/auth/v1/token?grant_type=password");
    expect(calls[0]!.body).toContain("dev@sendmeter.test");
    expect(calls[0]!.body).toContain("devpassword");
  });

  it("refreshes via the refresh_token grant", async () => {
    const calls: string[] = [];
    const client = createAuthClient("https://example.supabase.co", "anon-key", (async (input) => {
      const url = typeof input === "string" ? input : input.url;
      calls.push(url);
      return new Response(
        JSON.stringify({
          access_token: "at2",
          refresh_token: "rt2",
          expires_in: 3600,
          token_type: "bearer",
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }) as typeof fetch);
    await client.refresh("rt-stored");
    expect(calls[0]).toBe("https://example.supabase.co/auth/v1/token?grant_type=refresh_token");
  });
});
