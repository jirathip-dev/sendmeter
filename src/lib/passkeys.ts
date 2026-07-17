import { Capacitor } from "@capacitor/core";
import type { PasskeyListItem } from "@supabase/supabase-js";
import { SendLogPasskey } from "sendlog-passkey";
import { supabase } from "./supabase";

export type { PasskeyListItem };

const isNative = Capacitor.isNativePlatform();

/// WebAuthn availability. On the web the browser API works directly (origin =
/// sendmeter.app = the RP ID). Inside the native WebView the origin is
/// capacitor://localhost, which the browser API won't accept for the
/// sendmeter.app RP ID — so there we run the ceremony natively through the
/// SendLogPasskey plugin (ASAuthorization), authorized by the
/// webcredentials:sendmeter.app Associated Domain. Either way it's supported.
export const passkeysSupported =
  isNative || (typeof window !== "undefined" && !!window.PublicKeyCredential);

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

/// Enroll a passkey for the signed-in user. On web supabase-js runs the whole
/// browser ceremony; on native we drive the two-step Supabase flow (start →
/// native ASAuthorization → verify) ourselves.
export async function addPasskey(): Promise<void> {
  await requireSession();
  if (!isNative) {
    const { error } = await supabase.auth.registerPasskey();
    if (error) throw error;
    return;
  }

  const { data, error } = await supabase.auth.passkey.startRegistration();
  if (error) throw error;
  if (!data) throw new Error("No registration options returned");

  const opts = data.options;
  const rpId = opts.rp.id;
  if (!rpId) throw new Error("Server did not return a relying-party id");

  const cred = await SendLogPasskey.register({
    rpId,
    challenge: opts.challenge,
    userId: opts.user.id,
    userName: opts.user.name,
  });

  const { error: verifyError } = await supabase.auth.passkey.verifyRegistration({
    challengeId: data.challenge_id,
    credential: {
      id: cred.id,
      rawId: cred.rawId,
      type: "public-key",
      response: {
        attestationObject: cred.attestationObject,
        clientDataJSON: cred.clientDataJSON,
      },
      clientExtensionResults: {},
      authenticatorAttachment: "platform",
    },
  });
  if (verifyError) throw verifyError;
}

/// The signed-in user's enrolled passkeys — so the UI can list them (and offer
/// removal) instead of showing a stale "Add a passkey" after one exists.
export async function listPasskeys(): Promise<PasskeyListItem[]> {
  const { data, error } = await supabase.auth.passkey.list();
  if (error) throw error;
  return data ?? [];
}

/// Remove one enrolled passkey by id.
export async function removePasskey(passkeyId: string): Promise<void> {
  const { error } = await supabase.auth.passkey.delete({ passkeyId });
  if (error) throw error;
}

/// Sign in with a discoverable passkey — the OS shows the account picker, so
/// no email is needed up front. Sets the session on success. Same web/native
/// split as addPasskey.
export async function signInWithPasskey(): Promise<void> {
  if (!isNative) {
    const { error } = await supabase.auth.signInWithPasskey();
    if (error) throw error;
    return;
  }

  const { data, error } = await supabase.auth.passkey.startAuthentication();
  if (error) throw error;
  if (!data) throw new Error("No authentication options returned");

  const opts = data.options;
  const rpId = opts.rpId;
  if (!rpId) throw new Error("Server did not return a relying-party id");

  const cred = await SendLogPasskey.authenticate({
    rpId,
    challenge: opts.challenge,
    allowedCredentialIds: (opts.allowCredentials ?? []).map((c) => c.id),
  });

  const { error: verifyError } =
    await supabase.auth.passkey.verifyAuthentication({
      challengeId: data.challenge_id,
      credential: {
        id: cred.id,
        rawId: cred.rawId,
        type: "public-key",
        response: {
          authenticatorData: cred.authenticatorData,
          clientDataJSON: cred.clientDataJSON,
          signature: cred.signature,
          userHandle: cred.userHandle,
        },
        clientExtensionResults: {},
        authenticatorAttachment: "platform",
      },
    });
  if (verifyError) throw verifyError;
}
