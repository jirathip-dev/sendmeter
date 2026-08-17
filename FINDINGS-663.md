# Issue #663 — Native SIWA / passkey "JWT" error on device: findings

**Branch:** `native/663-auth-jwt` (based on staging)
**App under test:** native SwiftUI target `SendmeterNative`, bundle id
`com.jirathip.sendlog.native`, Supabase ref `zznsqmcewtzlnfoiefkk`
(hosted GoTrue **v2.195.0**, verified via `/auth/v1/health`).
**Reported:** Guy on-device (2026-08-16): *"JWT still issue at future"* after the
server-side AASA + Apple-client-ID fixes were applied.

---

## Executive verdict

The native auth **code is correct** and the **Supabase config is correct**. No
code-side fix is required — all three `swift test` / `xcodegen generate` /
`xcodebuild build` gates pass unchanged.

The failure is **on-device staleness**, not config or code:

1. **The installed build predates the AASA deploy and the capability-enabled
   provisioning profile.** Build 1 was uploaded before `sendmeter.app`
   `.well-known/apple-app-site-association` listed `com.jirathip.sendlog.native`
   and before the native App ID had SIWA + Associated Domains enabled
   (Fastfile enables those capabilities **at `native_beta` time**, and the
   profile is regenerated on every run — so build 1, cut earlier, may have
   been signed with a profile lacking the entitlements the auth sheets need).
2. **iOS caches the AASA.** Even with a correct build, the device can keep
   serving the old association (Capacitor app only) until the association is
   re-fetched.
3. **The error wording is Apple-side, not GoTrue-side.** GoTrue's actual
   rejection strings are `Unacceptable audience in id_token: [aud]`,
   `Nonces mismatch`, `Bad ID token`, or `Credential verification failed` —
   none say "not associated with domain". "Signed JWT … not associated with
   domain" is the signature of an **`ASAuthorizationError`** raised by the OS
   ceremony (SIWA sheet / passkey sheet) when the app's Associated-Domains
   entitlement is absent from the embedded provisioning profile or the
   device's AASA is stale — exactly hypothesis (a)/(d).

Per-hypothesis verdicts and the evidence behind them follow.

---

## Hypothesis (a) — Stale AASA cache / pre-fix build → device retest only

**VERDICT: SURVIVES. Most likely primary cause.**

Evidence:

- **AASA is correct and live** (fetched 2026-08-17, `ETag bea5022a…`,
  `Content-Type: application/json`, `Access-Control-Allow-Origin: *`):
  ```json
  {"applinks":{"details":[
    {"appIDs":["9244PWFYD7.com.jirathip.sendlog"],
     "components":[{"/":"/auth*","comment":"auth email redirects open the app"}]},
    {"appIDs":["9244PWFYD7.com.jirathip.sendlog.native"],
     "components":[{"/":"/auth*","comment":"auth email redirects open the native app"}]}
  ]},
  "webcredentials":{"apps":["9244PWFYD7.com.jirathip.sendlog",
                             "9244PWFYD7.com.jirathip.sendlog.native"]}}
  ```
  Team prefix is `9244PWFYD7`, which matches `TEAM_ID` in
  `fastlane/Fastfile:24`.
- **The native target's entitlements declare the required domains**
  (`native/SendmeterNative/SendmeterNative.entitlements:15-19`):
  `webcredentials:sendmeter.app` + `applinks:sendmeter.app`. It also declares
  SIWA (`com.apple.developer.applesignin`, `Default`, lines 11-14) and
  HealthKit (lines 5-10).
- **The Fastfile enables the App ID capabilities idempotently** at
  `native_beta` time: `APPLE_ID_AUTH` (as primary App ID), `ASSOCIATED_DOMAINS`,
  `HEALTHKIT` (`fastlane/Fastfile:493-526`). A **profile for build 1 may have
  been generated before those capabilities existed on the App ID**, so the
  embedded entitlements in the signed build 1 could be missing them → the OS
  auth sheets fail with "not associated". The lane also regenerates the
  profile with `force: true` every run (`Fastfile:548-553`), so a **fresh
  build is signed against the current capability set**.
- iOS caches `.well-known/apple-app-site-association`; Apple only refreshes it
  on network-state changes / reinstall / Developer-menu clear. A device that
  fetched the AASA before the native ID was added keeps serving the old one.

**Device retest (Guy) required — see steps at the bottom.**

---

## Hypothesis (b) — RP / origin mismatch for native passkey

**VERDICT: REJECTED statically. Server RP config matches what the native
ceremony produces.**

Evidence:

- **Server RP config (read-only GET, verified live):**
  `webauthn_rp_id = "sendmeter.app"`, `webauthn_rp_origins =
  "https://sendmeter.app"`, `passkey_enabled = true`.
- **Empirical:** `POST /auth/v1/passkeys/authentication/options` against the
  hosted project returns `{"options":{"rpId":"sendmeter.app",…}}` — the RP ID
  is what the client must present.
- **Native client** (`supabase-swift` pinned at `528bd5fb`, v2.55.1-10):
  `AuthClient+Passkey.swift` `signInWithPasskey`/`registerPasskey` read the
  RP ID **from the server-returned options** (`webAuthnAssertionRpId()`, line
  193 / `webAuthnCreationRpId()`, line 228) and hand it to
  `ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier:)`
  (`WebAuthnAuthenticator.swift:107-120`). `SupabaseService.swift:59-68`
  delegates straight to those APIs. Same seam as the working Capacitor plugin
  (`native-plugins/sendlog-passkey/ios/.../Plugin.swift:54-56`, driven by
  `src/lib/passkeys.ts`).
- **Origin validation** (go-webauthn v0.16.5, the version GoTrue pins —
  `go.mod:109`): assertion `Verify` → `CollectedClientData.Verify` →
  `IsOriginInHaystack(c.Origin, rpOrigins)` (`protocol/client.go:148-160`,
  `250-283`). `parseOriginURI` only treats `http(s)://` strings as URIs and
  compares scheme+host (`client.go:284-308`). A native platform passkey's
  `clientDataJSON.origin` is `"https://sendmeter.app"` (Apple reports
  `https://<rpId>`), which **exactly matches** `webauthn_rp_origins`. So a
  native assertion passes origin check.

**No config change needed — and `webauthn_rp_id` must NOT be changed**, since
WebAuthn credentials are cryptographically bound to it (changing it makes every
registered passkey unusable).

---

## Hypothesis (c) — `aud` mismatch in SIWA

**VERDICT: REJECTED statically. The identity token's `aud` is accepted.**

Evidence:

- **Server config (read-only GET, verified live):**
  `external_apple_client_id = "com.jirathip.sendlog.web,com.jirathip.sendlog,com.jirathip.sendlog.native"`
  — the `.native` id is present. `external_apple_enabled = true`.
  `external_apple_additional_client_ids = null` (not needed).
- **Native SIWA flow** (`LoginView.swift:93-97`): the `SignInWithAppleButton`
  sets no `appId`, so Apple issues the identity token with
  **`aud` = the app's bundle id = `com.jirathip.sendlog.native`**
  (`project.yml:60`). Nonce: `AppleAuthNonce.flow` hashes the raw nonce
  (`AppleAuthNonce.swift:30-33`), the raw value is passed to
  `signInWithIdToken` (`LoginView.swift:108-115` → `SupabaseService.swift:75-83`
  → `OpenIDConnectCredentials(provider: .apple, idToken:, nonce:)`).
- **GoTrue validation** (source, v2.195.0):
  - `internal/api/token_oidc.go:44-67` builds `acceptableClientIDs` for Apple
    from `config.External.Apple.ClientID` (the comma-split
    `external_apple_client_id`) plus `config.External.IosBundleId` (unset here).
  - `token_oidc.go:278-292`: the audience check is
    `slices.Contains(idToken.Audience, clientID)` for each acceptable id.
    `com.jirathip.sendlog.native` is in the list → **passes**.
  - Nonce: `token_oidc.go:294-307` re-hashes the passed raw nonce and compares
    to the token's `nonce` claim — identical to the web
    (`src/lib/appleAuth.ts:28-38`) and Capacitor-natives flows, which work.
- The known GoTrue rejection strings for this path are `Unacceptable audience
  in id_token: …`, `Nonces mismatch`, `Bad ID token` — **not** "not associated
  with domain".

**No code fix needed.** (Code hygiene note only: `AppleAuthNonce.clientID`
(`AppleAuthNonce.swift:21`) is a **dead constant** — the SIWA button never
reads it, so nothing passes it to Apple; the comment there is stale/misleading.
Harmless, and the `clientID` value `com.jirathip.sendlog` is the *Capacitor*
app's id, which this native target does not use. Not removed — out of scope and
covered by a test.)

---

## Hypothesis (d) — something else you can prove

**VERDICT: SUPPORTED — this is where the evidence points.**

- GoTrue v2.195.0 contains **no string** matching "not associated with domain"
  (full-source grep of `internal/`), and supabase-swift's `AuthError` only has
  `bad_jwt` / `invalid_jwt` / `jwtVerificationFailed` (`AuthError.swift:39,212,259`).
  So the phrase Guy saw is **an OS-level `ASAuthorizationError`**, not a GoTrue
  HTTP rejection.
- An `ASAuthorizationError` at the sheet (before any HTTP call) is caused by:
  1. the app's signed entitlements missing `com.apple.developer.associated-domains`
     / `com.apple.developer.applesignin` (build-1 profile predates capability
     enablement), and/or
  2. the device's cached AASA not listing `com.jirathip.sendlog.native`
     (AASA deployed after build 1; cache not refreshed).
  Both are fixed by **reinstall with a fresh `native_beta` build + an AASA
  cache refresh**, i.e. hypothesis (a).
- Secondary note on the wording "at future": if the failure is observed
  *after* a successful sign-in (e.g. at access-token expiry), the correct
  capture is the exact error + timestamp — supabase-swift's standard
  refresh-token rotation path is what's in play, not a JWT/domain check, and
  no native code deviates from the SDK's default session management. The
  Console capture below distinguishes sign-in-time vs post-sign-in failures.

---

## Gates

- `cd native/SendmeterNative && swift test` → **276 tests passed, 0 failures**.
- `xcodegen generate` → project generated cleanly (artifact is untracked and
  regenerated per `native_beta`; removed after gate).
- `xcodebuild -project SendmeterNative.xcodeproj -scheme SendmeterNative
  -destination 'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED**.

No source changes were made → no `RELEASE_NOTES.md` entry (internal-only).

---

## Device-retest steps for Guy

**Goal:** exercise the CURRENT backend (AASA + client IDs all patched) with a
fresh, correctly-signed build, and if it still fails, capture the failing
layer (OS ceremony vs GoTrue claim) instead of guessing.

1. **Ship a fresh build, not build 1.** Run `bundle exec fastlane native_beta`
   (or dispatch `native-testflight.yml`) so the App ID gets
   SIWA+Associated-Domains+HealthKit capabilities enabled and the profile is
   regenerated with them (`Fastfile:493-526,548-553`). Install **that** build.
2. **Uninstall first.** Delete "Sendmeter Native" from the phone (clears the
   app's stored session + WebAuthn account if re-registering).
3. **Refresh the AASA cache.** With the app installed: toggle **Airplane Mode
   OFF→ON**, then **relaunch** the app. (On a dev device, Settings → Developer
   → "Clear AASA Cache" works too.) Verify the device sees the new file by
   opening `https://sendmeter.app/.well-known/apple-app-site-association` in
   the device's Safari — it must list BOTH
   `9244PWFYD7.com.jirathip.sendlog` and
   `9244PWFYD7.com.jirathip.sendlog.native` under `webcredentials.apps`.
4. **Bootstrap sanity check:** email/password sign-in (proves network +
   session). Then **SIWA**, then **passkey** (register one from Settings →
   "Add a passkey" first, since no passkey exists yet).
5. **If a sheet never appears** (tap does nothing / immediate error):
   entitlement/profile problem — verify the embedded profile:
   `codesign -d --entitlements :- <path-to-Sendmeter.app>` and confirm
   `com.apple.developer.associated-domains` and `com.apple.developer.applesignin`
   are present. If the **SIWA sheet appears but errors after selection**, that's
   AASA/Apple-side (step 3).
6. **Console.app capture** (macOS, phone plugged in):
   - Predicate: `process == "Sendmeter" OR (subsystem CONTAINS "com.apple.AuthenticationServices") OR (senderImagePath CONTAINS "AuthKit")`
   - Trigger the failing action, then look for `ASAuthorizationError`,
     `authorization`, `associated`, `webcredentials`, `apple-app-site-association`.
   - Grab the **exact error string + HTTP status + request/response body** if a
     `token?grant_type=id_token` or `passkeys/…/verify` call happened (GoTrue
     errors say `Unacceptable audience`, `Nonces mismatch`, `Bad ID token`,
     `Credential verification failed`; an OS error is `ASAuthorizationError`).
   - Note the **timestamp** relative to sign-in: a failure **at** sign-in points
     at the ceremony/AASA; a failure **later** (at token refresh) is a
     different path — capture that too.
   - Command-line alternative: `log stream --level debug --predicate 'process == "Sendmeter"'` while reproducing.

**Acceptance:** fresh install of the post-fix build completes SIWA + passkey
with no error, OR the captured Console log names the exact failing layer.

---

## Config changes the orchestrator should apply (if any)

**None to Supabase** — `external_apple_client_id`,
`webauthn_rp_id`/`webauthn_rp_origins`, `uri_allow_list` are verified correct
(read-only GET). **Do not touch `webauthn_rp_id`.**

The only portal-side item is already automated and idempotent in
`fastlane native_beta` (App ID capabilities for `com.jirathip.sendlog.native`).
If a device retest still fails with an `ASAuthorizationError`, re-run
`native_beta` (forces a fresh capability-carrying profile) before any other
change.
