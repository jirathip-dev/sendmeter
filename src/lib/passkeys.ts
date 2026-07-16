import { supabase } from "./supabase";

/// WebAuthn availability. Passkeys work reliably on the web (origin =
/// sendmeter.app = the RP ID). In the native WebView the origin is
/// capacitor://localhost, which doesn't match the sendmeter.app RP ID, so
/// passkeys there depend on Associated Domains (webcredentials:sendmeter.app)
/// and are device-only to verify.
export const passkeysSupported =
  typeof window !== "undefined" && !!window.PublicKeyCredential;

/// Ensure there's a live session before an authenticated passkey call.
/// getSession() auto-refreshes a merely-expired session; a null result means
/// the stored session is gone/revoked, so registerPasskey/list would fail with
/// the opaque "Auth session missing!" — surface an actionable message instead.
async function requireSession() {
  const { data } = await supabase.auth.getSession();
  if (!data.session) {
    throw new Error(
      "Your session has expired. Please sign out and sign in again, then add a passkey.",
    );
  }
}

/// Enroll a passkey for the signed-in user (runs the full WebAuthn create
/// ceremony via Supabase). Call from Account settings.
export async function addPasskey(): Promise<void> {
  await requireSession();
  const { error } = await supabase.auth.registerPasskey();
  if (error) throw error;
}

/// How many passkeys the signed-in user has enrolled — so the UI can show
/// "enabled" instead of a stale "Add a passkey" after one exists.
export async function passkeyCount(): Promise<number> {
  const { data, error } = await supabase.auth.passkey.list();
  if (error) throw error;
  return data?.length ?? 0;
}

/// Sign in with a discoverable passkey — the OS shows the account picker, so
/// no email is needed up front. Sets the session on success.
export async function signInWithPasskey(): Promise<void> {
  const { error } = await supabase.auth.signInWithPasskey();
  if (error) throw error;
}
