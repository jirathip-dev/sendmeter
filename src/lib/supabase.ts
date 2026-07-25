import { createClient } from "@supabase/supabase-js";
import type { Database } from "../types/database";

// Public client config — the publishable key is safe to commit (it ships in
// every browser bundle regardless; RLS is the security boundary). Env vars
// override for local/dev flexibility.
export const SUPABASE_URL =
  import.meta.env.VITE_SUPABASE_URL ?? "https://zznsqmcewtzlnfoiefkk.supabase.co";
const SUPABASE_ANON_KEY =
  import.meta.env.VITE_SUPABASE_ANON_KEY ??
  "sb_publishable_eHRHTelsNVGOcURw4q9a1Q_r6sas-rp";

export const supabase = createClient<Database>(SUPABASE_URL, SUPABASE_ANON_KEY, {
  // Passkeys are experimental in supabase-js and require this explicit opt-in.
  auth: { experimental: { passkey: true } },
});
