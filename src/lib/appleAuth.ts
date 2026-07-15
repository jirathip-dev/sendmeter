import { Capacitor } from "@capacitor/core";
import { SignInWithApple } from "@capacitor-community/apple-sign-in";
import { supabase } from "./supabase";
import { authRedirectUrl } from "./authRedirect";

export const IS_NATIVE = Capacitor.isNativePlatform();

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/// Sign in with Apple → Supabase session.
/// - Native iOS: the OS's native Apple sheet, then exchange the identity token.
///   Apple echoes the (hashed) nonce we send into the token's `nonce` claim;
///   Supabase re-hashes the raw nonce we pass and compares. If a device test
///   ever rejects the nonce, the fix is a one-liner (send/compare raw on both).
/// - Web: standard OAuth redirect to Apple.
///
/// Same email across providers auto-links to one account (unless the user
/// picks Apple's "Hide My Email", which yields a distinct relay address).
export async function signInWithApple(): Promise<void> {
  if (IS_NATIVE) {
    const rawNonce = crypto.randomUUID();
    const hashedNonce = await sha256Hex(rawNonce);
    const { response } = await SignInWithApple.authorize({
      clientId: "com.jirathip.sendlog",
      redirectURI: authRedirectUrl(),
      scopes: "email name",
      nonce: hashedNonce,
    });
    const { error } = await supabase.auth.signInWithIdToken({
      provider: "apple",
      token: response.identityToken,
      nonce: rawNonce,
    });
    if (error) throw error;
  } else {
    const { error } = await supabase.auth.signInWithOAuth({
      provider: "apple",
      options: { redirectTo: authRedirectUrl() },
    });
    if (error) throw error;
  }
}
