/// Environment resolution for the sendmeter-mcp server.
///
/// The hosted Supabase project's URL + publishable anon key are the defaults
/// (the key is a publishable credential, committed in the web app already;
/// RLS is the security boundary). Everything is overridable for the local
/// Supabase stack and for test/dry-run modes. The user's ACCESS token is
/// never configurable here — see auth.ts.

export const DEFAULT_SUPABASE_URL = "https://zznsqmcewtzlnfoiefkk.supabase.co";
export const DEFAULT_SUPABASE_ANON_KEY =
  "sb_publishable_eHRHTelsNVGOcURw4q9a1Q_r6sas-rp";

export interface ServerConfig {
  supabaseUrl: string;
  supabaseAnonKey: string;
  /// A ready-made user access token (Bearer). Highest-precedence credential;
  /// never persisted, never refreshed.
  accessToken: string | null;
  email: string | null;
  password: string | null;
  /// Session-file path override (default: ~/.sendmeter-mcp/session.json).
  sessionFile: string | null;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServerConfig {
  return {
    supabaseUrl: env["SENDMETER_MCP_URL"] ?? DEFAULT_SUPABASE_URL,
    supabaseAnonKey: env["SENDMETER_MCP_ANON_KEY"] ?? DEFAULT_SUPABASE_ANON_KEY,
    accessToken: env["SENDMETER_MCP_TOKEN"] ?? null,
    email: env["SENDMETER_MCP_EMAIL"] ?? null,
    password: env["SENDMETER_MCP_PASSWORD"] ?? null,
    sessionFile: env["SENDMETER_MCP_SESSION_FILE"] ?? null,
  };
}
