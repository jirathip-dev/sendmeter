/// Native passkey (WebAuthn) bridge. The browser WebAuthn API can't run in the
/// Capacitor WebView because its origin is capacitor://localhost, which can't
/// match the sendmeter.app RP ID. This plugin runs the ceremony natively via
/// ASAuthorization (Face ID / Touch ID), authorized by the
/// webcredentials:sendmeter.app Associated Domain. All binary fields cross the
/// bridge as **base64url** strings — the same encoding Supabase's WebAuthn
/// endpoints use — so the JS side needs no re-encoding.
export interface PasskeyRegisterOptions {
  /// Relying-party id = the domain the passkey is scoped to (sendmeter.app).
  rpId: string;
  /// Server challenge, base64url.
  challenge: string;
  /// User handle, base64url.
  userId: string;
  /// Account name shown in the OS sheet (e.g. email).
  userName: string;
}

export interface PasskeyRegisterResult {
  /// Credential id, base64url (id === rawId in JSON form).
  id: string;
  rawId: string;
  /// CBOR attestation object, base64url.
  attestationObject: string;
  /// clientDataJSON, base64url.
  clientDataJSON: string;
}

export interface PasskeyAuthenticateOptions {
  rpId: string;
  /// Server challenge, base64url.
  challenge: string;
  /// Optional allow-list of credential ids (base64url). Empty = discoverable.
  allowedCredentialIds?: string[];
}

export interface PasskeyAuthenticateResult {
  id: string;
  rawId: string;
  authenticatorData: string;
  clientDataJSON: string;
  signature: string;
  /// User handle, base64url (present for discoverable credentials).
  userHandle?: string;
}

export interface SendLogPasskeyPlugin {
  /// Whether the OS can run the platform passkey ceremony (iOS 16+).
  isSupported(): Promise<{ supported: boolean }>;
  /// Create a passkey (registration ceremony). Rejects with a message
  /// containing "cancel" if the user dismisses the sheet.
  register(options: PasskeyRegisterOptions): Promise<PasskeyRegisterResult>;
  /// Assert an existing passkey (authentication ceremony).
  authenticate(
    options: PasskeyAuthenticateOptions,
  ): Promise<PasskeyAuthenticateResult>;
}
