import { supabase } from "./supabase";

/// WebAuthn availability. Passkeys work reliably on the web (origin =
/// sendmeter.app = the RP ID). In the native WebView the origin is
/// capacitor://localhost, which doesn't match the sendmeter.app RP ID, so
/// passkeys there depend on Associated Domains (webcredentials:sendmeter.app)
/// and are device-only to verify.
export const passkeysSupported =
  typeof window !== "undefined" && !!window.PublicKeyCredential;

/// Enroll a passkey for the signed-in user (runs the full WebAuthn create
/// ceremony via Supabase). Call from Account settings.
export async function addPasskey(): Promise<void> {
  const { error } = await supabase.auth.registerPasskey();
  if (error) throw error;
}

/// Sign in with a discoverable passkey — the OS shows the account picker, so
/// no email is needed up front. Sets the session on success.
export async function signInWithPasskey(): Promise<void> {
  const { error } = await supabase.auth.signInWithPasskey();
  if (error) throw error;
}
