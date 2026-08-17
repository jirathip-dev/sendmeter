/// Session bootstrap tests: credential precedence (env token > email/password
/// > interactive prompt), the password-grant login against a recorded fetch,
/// and the TokenProvider's 401-driven re-authentication (single login shared
/// across concurrent 401s, AuthRequiredError when no credentials exist).
/// #644 review F6: there is no session file and no refresh token anywhere —
/// the suite pins that too (see invariants.test.ts).

import { describe, expect, it } from "vitest";
import {
  createAuthClient,
  createTokenProvider,
  resolveSession,
  type AuthClient,
} from "../src/auth.js";
import { AuthRequiredError } from "../src/transport.js";

function baseConfig(overrides: Record<string, string | null> = {}) {
  return {
    supabaseUrl: "https://example.supabase.co",
    supabaseAnonKey: "anon-key",
    accessToken: null,
    email: null,
    password: null,
    ...overrides,
  };
}

function fakeAuth(): AuthClient & { logins: [string, string][] } {
  const calls: { logins: [string, string][] } = { logins: [] };
  return {
    async signInPassword(email, password) {
      calls.logins.push([email, password]);
      return { accessToken: `at-${email}`, email };
    },
    ...calls,
  };
}

describe("resolveSession", () => {
  it("prefers the env token and never signs in", async () => {
    const auth = fakeAuth();
    const out = await resolveSession({
      config: baseConfig({ accessToken: "env-token" }),
      auth,
    });
    expect(out).toEqual({ accessToken: "env-token", email: null, origin: "env-token" });
    expect(auth.logins).toEqual([]);
  });

  it("signs in with env credentials when no token is set", async () => {
    const auth = fakeAuth();
    const out = await resolveSession({
      config: baseConfig({ email: "dev@sendmeter.test", password: "devpassword" }),
      auth,
    });
    expect(auth.logins).toEqual([["dev@sendmeter.test", "devpassword"]]);
    expect(out).toEqual({
      accessToken: "at-dev@sendmeter.test",
      email: "dev@sendmeter.test",
      origin: "login",
    });
  });

  it("uses the interactive prompt when provided and no env credentials exist", async () => {
    const auth = fakeAuth();
    const out = await resolveSession({
      config: baseConfig(),
      auth,
      prompt: async () => "dev@sendmeter.test",
    });
    // Both the email and password prompts return the same canned value.
    expect(auth.logins).toEqual([["dev@sendmeter.test", "dev@sendmeter.test"]]);
    expect(out.origin).toBe("login");
    expect(out.email).toBe("dev@sendmeter.test");
  });

  it("fails with instructions when nothing is available", async () => {
    await expect(
      resolveSession({ config: baseConfig(), auth: fakeAuth() }),
    ).rejects.toThrow(/SENDMETER_MCP_TOKEN/);
  });
});

describe("createAuthClient", () => {
  it("signs in via the password grant (POST /auth/v1/token?grant_type=password)", async () => {
    const calls: { method: string; url: string; body: string }[] = [];
    const client = createAuthClient("https://example.supabase.co", "anon-key", (async (input, init) => {
      const url = typeof input === "string" ? input : input instanceof Request ? input.url : String(input);
      const method = init?.method ?? (typeof input === "string" ? "GET" : input instanceof Request ? input.method : "GET");
      const body = init?.body ? String(init.body) : "";
      calls.push({ method, url, body });
      return new Response(
        JSON.stringify({
          access_token: "at-password",
          refresh_token: "rt-ignored",
          expires_in: 3600,
          token_type: "bearer",
          user: { email: "dev@sendmeter.test", id: "11111111-1111-1111-1111-111111111111" },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }) as typeof fetch);

    const result = await client.signInPassword("dev@sendmeter.test", "devpassword");
    // The response carries a refresh token, but the server never stores or
    // returns it — AuthResult only carries the access token (#644 review F6).
    expect(result.accessToken).toBe("at-password");
    expect(result.email).toBe("dev@sendmeter.test");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe("POST");
    expect(calls[0]!.url).toBe("https://example.supabase.co/auth/v1/token?grant_type=password");
    expect(calls[0]!.body).toContain("dev@sendmeter.test");
    expect(calls[0]!.body).toContain("devpassword");
  });
});

describe("createTokenProvider", () => {
  function provider(opts: {
    email?: string | null;
    password?: string | null;
    prompt?: boolean;
    initial?: string;
    initialEmail?: string | null;
  } = {}) {
    const auth = fakeAuth();
    const token = createTokenProvider({
      auth,
      email: opts.email ?? null,
      password: opts.password ?? null,
      prompt:
        opts.prompt ?
          (async () => "dev@sendmeter.test") as never
        : undefined,
      initial: opts.initial ?? "at-initial",
      initialEmail: opts.initialEmail ?? null,
    });
    return { auth, token };
  }

  it("returns the initial access token until a 401 rotates it", async () => {
    const { auth, token } = provider({ email: "dev@sendmeter.test", password: "devpassword" });
    expect(await token.get()).toBe("at-initial");
    await token.onUnauthorized();
    expect(await token.get()).toBe("at-dev@sendmeter.test");
    expect(auth.logins).toEqual([["dev@sendmeter.test", "devpassword"]]);
  });

  it("serialises concurrent 401s into a single re-login", async () => {
    const { auth, token } = provider({ email: "dev@sendmeter.test", password: "devpassword" });
    await Promise.all([token.onUnauthorized(), token.onUnauthorized(), token.onUnauthorized()]);
    expect(auth.logins).toHaveLength(1);
  });

  it("throws AuthRequiredError when the token expired and no credentials exist", async () => {
    const { auth, token } = provider();
    await expect(token.onUnauthorized()).rejects.toThrow(AuthRequiredError);
    expect(auth.logins).toEqual([]);
  });

  it("throws AuthRequiredError when re-sign-in fails", async () => {
    const { auth, token } = provider({ email: "dev@sendmeter.test", password: "wrong" });
    auth.signInPassword = async () => {
      throw new Error("invalid login credentials");
    };
    await expect(token.onUnauthorized()).rejects.toThrow(AuthRequiredError);
    await expect(token.onUnauthorized()).rejects.toThrow(/invalid login credentials/);
  });

  it("falls back to the interactive prompt when env credentials are absent", async () => {
    const { auth, token } = provider({ prompt: true });
    await token.onUnauthorized();
    expect(await token.get()).toBe("at-dev@sendmeter.test");
    expect(auth.logins).toEqual([["dev@sendmeter.test", "dev@sendmeter.test"]]);
  });
});
