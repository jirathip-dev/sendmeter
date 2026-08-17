/// Session bootstrap for the MCP server. The server authenticates as THE
/// USER — it never holds a service-role key.
///
/// #644 review F6 — the server does NOT mint or persist a refresh token, and
/// keeps no session file. Repo invariant (nativeAuthInvariants.test.ts): only
/// supabase-js in the web app holds refresh tokens. This server signs in with
/// `grant_type=password`, keeps the resulting ACCESS token in memory only,
/// and when that token expires re-signs-in (env credentials, or an
/// interactive prompt) or — with no credentials available — exits with a
/// clear re-authentication instruction. No refresh token is ever stored on
/// disk, on the wire, or in a long-lived holder.
///
/// The login path is deliberately "password sign-in", NOT "PKCE" (issue #644
/// review F11): `grant_type=password` POSTs the credentials to
/// `/auth/v1/token` — PKCE governs OAuth/magic-link redirect flows and the
/// option is inert for a password grant.

import * as readline from "node:readline";
import { createClient } from "@supabase/supabase-js";
import type { ServerConfig } from "./config.js";
import { AuthRequiredError, type TokenProvider } from "./transport.js";

export interface AuthResult {
  accessToken: string;
  email: string;
}

export interface AuthClient {
  signInPassword(email: string, password: string): Promise<AuthResult>;
}

export function createAuthClient(
  url: string,
  anonKey: string,
  fetchImpl?: typeof fetch,
): AuthClient {
  const client = createClient(url, anonKey, {
    global: { fetch: fetchImpl },
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
  return {
    async signInPassword(email, password) {
      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw new Error(`sign-in failed: ${error.message}`);
      if (!data.session) throw new Error("sign-in failed: no session returned");
      return {
        accessToken: data.session.access_token,
        email: data.user?.email ?? email,
      };
    },
  };
}

export interface ResolvedSession {
  accessToken: string;
  email: string | null;
  origin: "env-token" | "login";
}

/// Resolve the credential the server will use. Order: env token → env
/// email/password → interactive prompt (TTY only). Throws a descriptive
/// error when nothing can be resolved.
export async function resolveSession(opts: {
  config: ServerConfig;
  auth: AuthClient;
  prompt?: typeof promptHidden;
}): Promise<ResolvedSession> {
  const { config } = opts;

  if (config.accessToken) {
    return { accessToken: config.accessToken, email: null, origin: "env-token" };
  }

  if (config.email && config.password) {
    const result = await opts.auth.signInPassword(config.email, config.password);
    return { accessToken: result.accessToken, email: result.email, origin: "login" };
  }

  if (opts.prompt) {
    const email = await opts.prompt("Sendmeter email: ", false);
    const password = await opts.prompt("Sendmeter password: ", true);
    if (email.trim()) {
      const result = await opts.auth.signInPassword(email.trim(), password);
      return { accessToken: result.accessToken, email: result.email, origin: "login" };
    }
  }

  throw new Error(
    "no Sendmeter session available. Set SENDMETER_MCP_TOKEN (an access token from the " +
      "app), or SENDMETER_MCP_EMAIL + SENDMETER_MCP_PASSWORD, or run interactively " +
      "to sign in. See mcp/README.md.",
  );
}

/// Build a TokenProvider that re-signs-in with the configured credentials
/// when the current access token is rejected (HTTP 401) — the compensating
/// mechanism for "no refresh token on disk" (issue #644 review F5). The
/// rotation runs at most once per call and is serialised, so two concurrent
/// 401s share one login. With no credentials to re-sign-in with it throws
/// AuthRequiredError, which the transport surfaces as a structured error.
export function createTokenProvider(opts: {
  auth: AuthClient;
  email: string | null;
  password: string | null;
  prompt?: typeof promptHidden;
  initial: string;
  initialEmail: string | null;
}): TokenProvider {
  let token = opts.initial;
  let email = opts.initialEmail;
  let inFlight: Promise<void> | null = null;
  return {
    async get() {
      return token;
    },
    async onUnauthorized() {
      if (opts.email && opts.password) {
        inFlight ??= opts.auth.signInPassword(opts.email, opts.password).then(
          (r) => {
            token = r.accessToken;
            email = r.email;
          },
          (err) => {
            throw new AuthRequiredError(
              `access token expired and re-sign-in failed (${err instanceof Error ? err.message : String(err)}). ` +
                `Set a fresh SENDMETER_MCP_TOKEN or correct SENDMETER_MCP_EMAIL/SENDMETER_MCP_PASSWORD.`,
            );
          },
        );
        try {
          await inFlight;
        } finally {
          inFlight = null;
        }
        return;
      }
      if (opts.prompt) {
        const promptedEmail = await opts.prompt("Sendmeter email: ", false);
        const password = await opts.prompt("Sendmeter password: ", true);
        if (promptedEmail.trim()) {
          const r = await opts.auth.signInPassword(promptedEmail.trim(), password);
          token = r.accessToken;
          email = r.email;
          return;
        }
      }
      throw new AuthRequiredError(
        `access token expired (${email ?? "token-authenticated user"}). ` +
          `Set a fresh SENDMETER_MCP_TOKEN or SENDMETER_MCP_EMAIL/SENDMETER_MCP_PASSWORD and restart.`,
      );
    },
  };
}

/// Minimal hidden-input prompt (no deps). Falls back to visible input if the
/// terminal doesn't support raw mode.
export async function promptHidden(question: string, hidden: boolean): Promise<string> {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    throw new Error("not a TTY — set SENDMETER_MCP_EMAIL/SENDMETER_MCP_PASSWORD instead");
  }
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise<string>((resolve) => {
    if (!hidden) {
      rl.question(question, resolve);
      return;
    }
    process.stdout.write(question);
    process.stdin.setRawMode(true);
    let buf = "";
    const onData = (chunk: Buffer) => {
      const c = chunk.toString();
      if (c === "\r" || c === "\n") {
        cleanup();
        process.stdout.write("\n");
        resolve(buf);
      } else if (c === "\u0003") {
        cleanup();
        resolve("");
      } else if (c === "\u007f" || c === "\b") {
        buf = buf.slice(0, -1);
      } else {
        buf += c;
      }
    };
    const cleanup = () => {
      process.stdin.removeListener("data", onData);
      process.stdin.setRawMode(false);
      rl.close();
    };
    process.stdin.on("data", onData);
  });
  return answer;
}
