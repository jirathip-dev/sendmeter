/// Session bootstrap for the MCP server. The server authenticates as THE
/// USER — it never holds a service-role key. It either consumes a ready-made
/// access token (env), or performs its own PKCE password sign-in against the
/// Supabase project and persists the resulting session (access + refresh) in
/// a 0600 file under ~/.sendmeter-mcp/session.json, refreshing it on later
/// runs when it nears expiry.
///
/// The refresh token the server stores is minted by its OWN sign-in and is
/// the only holder of that credential — it never imports the web app's or
/// the watch's refresh token (those are single-use with reuse detection; a
/// second holder presenting one the app has rotated revokes the whole
/// session family).

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as readline from "node:readline";
import { createClient } from "@supabase/supabase-js";
import type { ServerConfig } from "./config.js";

export interface StoredSession {
  accessToken: string;
  refreshToken: string;
  /** Unix seconds (Supabase's `expires_at`). */
  expiresAt: number;
  email: string;
}

export interface ResolvedSession {
  accessToken: string;
  email: string | null;
  origin: "env-token" | "session-file" | "login";
}

export interface AuthResult {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  email: string;
}

export interface AuthClient {
  signInPassword(email: string, password: string): Promise<AuthResult>;
  refresh(refreshToken: string): Promise<AuthResult>;
}

export function createAuthClient(
  url: string,
  anonKey: string,
  fetchImpl?: typeof fetch,
): AuthClient {
  const client = createClient(url, anonKey, {
    global: { fetch: fetchImpl },
    auth: {
      flowType: "pkce",
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
        refreshToken: data.session.refresh_token,
        expiresAt: data.session.expires_at ?? 0,
        email,
      };
    },
    async refresh(refreshToken) {
      const { data, error } = await client.auth.refreshSession({ refresh_token: refreshToken });
      if (error) throw new Error(`session refresh failed: ${error.message}`);
      if (!data.session) throw new Error("session refresh failed: no session returned");
      return {
        accessToken: data.session.access_token,
        refreshToken: data.session.refresh_token,
        expiresAt: data.session.expires_at ?? 0,
        email: data.user?.email ?? "",
      };
    },
  };
}

export function defaultSessionFilePath(env: NodeJS.ProcessEnv = process.env): string {
  if (env["SENDMETER_MCP_SESSION_FILE"]) return env["SENDMETER_MCP_SESSION_FILE"]!;
  return path.join(os.homedir(), ".sendmeter-mcp", "session.json");
}

export function loadStoredSession(file: string): StoredSession | null {
  try {
    const raw = fs.readFileSync(file, "utf8");
    const parsed = JSON.parse(raw) as Partial<StoredSession>;
    if (
      typeof parsed.accessToken === "string" &&
      typeof parsed.refreshToken === "string" &&
      typeof parsed.expiresAt === "number" &&
      typeof parsed.email === "string"
    ) {
      return parsed as StoredSession;
    }
    return null;
  } catch {
    return null;
  }
}

export function saveStoredSession(file: string, session: StoredSession): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(session), { mode: 0o600 });
  fs.renameSync(tmp, file);
  fs.chmodSync(file, 0o600);
}

export function clearStoredSession(file: string): void {
  try {
    fs.unlinkSync(file);
  } catch {
    // Absent file is fine — nothing to clear.
  }
}

const EXPIRY_SKEW_S = 60;

function sessionUsable(s: StoredSession): boolean {
  return s.expiresAt === 0 || s.expiresAt > Math.floor(Date.now() / 1000) + EXPIRY_SKEW_S;
}

/// Resolve the credential the server will use. Order: env token → session
/// file (refreshed when near expiry) → env email/password → interactive
/// prompt (TTY only). Throws a descriptive error when nothing can be
/// resolved.
export async function resolveSession(opts: {
  config: ServerConfig;
  auth: AuthClient;
  sessionFile?: string;
  prompt?: typeof promptHidden;
}): Promise<ResolvedSession> {
  const { config } = opts;
  const sessionFile = opts.sessionFile ?? defaultSessionFilePath();

  if (config.accessToken) {
    return { accessToken: config.accessToken, email: null, origin: "env-token" };
  }

  const stored = loadStoredSession(sessionFile);
  if (stored) {
    if (sessionUsable(stored)) {
      return { accessToken: stored.accessToken, email: stored.email, origin: "session-file" };
    }
    try {
      const refreshed = await opts.auth.refresh(stored.refreshToken);
      const next: StoredSession = {
        accessToken: refreshed.accessToken,
        refreshToken: refreshed.refreshToken,
        expiresAt: refreshed.expiresAt,
        email: refreshed.email || stored.email,
      };
      saveStoredSession(sessionFile, next);
      return { accessToken: next.accessToken, email: next.email, origin: "session-file" };
    } catch (err) {
      // The stored refresh token was revoked or the network is down. Drop
      // the dead credential so the next attempt starts clean, then fall
      // through to a fresh login if credentials are available.
      clearStoredSession(sessionFile);
      const refreshError =
        err instanceof Error ? err.message : "unknown error";
      if (config.email && config.password) {
        return loginAndPersist(opts.auth, sessionFile, config.email, config.password);
      }
      if (opts.prompt) {
        const email = await opts.prompt("Sendmeter email: ", false);
        const password = await opts.prompt("Sendmeter password: ", true);
        if (email.trim()) {
          return loginAndPersist(opts.auth, sessionFile, email.trim(), password);
        }
      }
      throw new Error(
        `stored session expired and could not be refreshed (${refreshError}). ` +
          `Sign in again with SENDMETER_MCP_EMAIL/SENDMETER_MCP_PASSWORD or a fresh ` +
          `SENDMETER_MCP_TOKEN.`,
      );
    }
  }

  if (config.email && config.password) {
    return loginAndPersist(opts.auth, sessionFile, config.email, config.password);
  }

  if (opts.prompt) {
    const email = await opts.prompt("Sendmeter email: ", false);
    const password = await opts.prompt("Sendmeter password: ", true);
    if (email.trim()) {
      return loginAndPersist(opts.auth, sessionFile, email.trim(), password);
    }
  }

  throw new Error(
    "no Sendmeter session available. Set SENDMETER_MCP_TOKEN (an access token from the " +
      "app), or SENDMETER_MCP_EMAIL + SENDMETER_MCP_PASSWORD, or run interactively " +
      "to sign in. See mcp/README.md.",
  );
}

async function loginAndPersist(
  auth: AuthClient,
  sessionFile: string,
  email: string,
  password: string,
): Promise<ResolvedSession> {
  const result = await auth.signInPassword(email, password);
  const session: StoredSession = {
    accessToken: result.accessToken,
    refreshToken: result.refreshToken,
    expiresAt: result.expiresAt,
    email: result.email,
  };
  saveStoredSession(sessionFile, session);
  return { accessToken: result.accessToken, email: result.email, origin: "login" };
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
