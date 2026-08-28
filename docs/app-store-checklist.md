# App Store submission checklist (Sendmeter iOS + Sendmeter Watch)

Everything code-side is done in this repo. This file is the copy-paste guide
for the App Store Connect forms.

## Native app submission (the current path — #719)

App Review prep is now scoped to the **native** app. The canonical reviewer
notes are `docs/app-review-notes.md` (paste-verbatim Notes). The two
`[FILL IN]` placeholders (demo credentials, tested devices/OS) and the physical
iPhone + Watch screen recording are the human/Apple-only steps; everything else
is in-repo.

- **Bundle / app record**: the native Release target ships to the existing
  Sendmeter TestFlight record under `com.jirathip.sendlog` (fastlane
  `native_beta`, #637) and embeds the `com.jirathip.sendlog.watchkitapp`
  companion. The lane provisions profiles for the phone app, embedded watch
  app, and phone widget appex. Debug keeps `com.jirathip.sendlog.native` only
  for side-by-side development; it cannot pair with the watch companion.
- **Privacy manifests** (`PrivacyInfo.xcprivacy`, one per shipped bundle):
  app `native/SendmeterNative/Resources/PrivacyInfo.xcprivacy` (required-reason
  UserDefaults `CA92.1` + SystemBootTime `35F9.1`), the embedded Watch app
  `ios/App/SendLogWatch Watch App/PrivacyInfo.xcprivacy` (UserDefaults and
  FileTimestamp reasons), and the Live Activity appex
  `native/SendmeterNative/Resources/Widgets/PrivacyInfo.xcprivacy` (no
  required-reason API). All declare `NSPrivacyTracking = false`, no
  `NSPrivacyTrackingDomains`.
- **App Privacy answers** ("nutrition label"): Email Address, Health, Fitness,
  Other User Content and Coarse Location, all **Used for Tracking: No** and
  **Purpose: App Functionality only**; linked to identity **Yes** except
  **Coarse Location, which is No** (rounded to ~1 km for the Open-Meteo Send
  Conditions lookup, never tied to the account). There is **no Diagnostics
  row** — the native target omits the web Sentry SDK, so no error/diagnostic
  data leaves the device — and **no App Tracking Transparency prompt** (no
  advertising/analytics/attribution SDK, no IDFA).
- **No-tracking verification**: `rg -i
  'ATTrackingManager|AppTrackingTransparency|AdSupport|IDFA|asIdentifierManager|GoogleAnalytics|Mixpanel|Amplitude|AppsFlyer'
  native/SendmeterNative` should return nothing. The only required-reason APIs
  are `UserDefaults` (`CA92.1`, plain `.standard` — no App Group) and
  `SystemBootTime` (`35F9.1`, `ProcessInfo.systemUptime` for elapsed-time
  measurement); there is no file-metadata or disk-space API.

> **This file is now the native submission checklist.** Everything below this
> banner documents the **superseded Capacitor build** (`ios/App/App`,
> `src/lib/*`, `@capacitor/*`, the web Sentry SDK, and bundled Inter). It is
> **NOT the submission path** and is
> kept for reference only.
>
> Items that **also apply to the native submission**: privacy policy URL
> (`public/privacy.html`), support URL (`public/support.html`), in-app account
> deletion, password sign-in, Sign in with Apple, export compliance, and the age
> rating questionnaire.
>
> Capacitor-only items that do **NOT describe the native binary**: the
> `ios/App/App` privacy manifests, web Sentry / Diagnostics, and the bundled
> Inter typeface. The native Release configuration includes the shared Apple
> Watch companion under `com.jirathip.sendlog.watchkitapp` and its existing
> watch-widget extension under `com.jirathip.sendlog.watchkitapp.widgets`; it
> uses the native privacy manifests (`native/SendmeterNative/Resources/…`) and
> declares no
> Diagnostics data type, and its phone required-reason APIs are only
> `UserDefaults` (`CA92.1`) + `SystemBootTime` (`35F9.1`).

## Already handled in the repo ✅

- **App icons**: generated from `scripts/icon.svg` via `node scripts/generate-icons.mjs`
  into the iOS asset catalog, watch asset catalog, and PWA icons. Opaque (no alpha),
  as the 1024px marketing icon requires.
- **Privacy policy page**: `public/privacy.html` → will be live at
  `https://<your-domain>/privacy.html` once the web app deploys. That URL goes in
  App Store Connect → App Privacy → Privacy Policy URL.
- **Support page**: `public/support.html` → `https://sendmeter.app/support.html`.
  Use this for the required version-level Support URL; it contains contact,
  troubleshooting, account-deletion, and privacy information.
- **In-app account deletion** (guideline 5.1.1(v)): Account sheet → Danger zone →
  Delete account. Removes the auth user; every table cascades.
- **Password sign-in**: needed for the reviewer demo account (magic-link-only apps
  are painful to review).
- **Usage strings**: Bluetooth (iOS + watch), HealthKit share/read, Motion,
  Location (when-in-use only, for Send Conditions) — all set.
- **Sign in with Apple**: offered (#496 — this file used to claim email-only
  auth, which was false). `src/lib/appleAuth.ts` wires the native flow
  (`SignInWithApple.authorize` → Supabase `signInWithIdToken`) and the web
  OAuth redirect (`signInWithOAuth(provider: "apple")`), rendered from
  `LoginScreen.tsx`. Since Apple is the only third-party login offered,
  guideline 4.8's "must also offer Sign in with Apple" rule is satisfied by
  construction. What Apple provides on that path (the email address — possibly
  a Hide-My-Email relay address) is covered by the Email Address row in the
  App Privacy table below; confirm the App Store Connect answers reflect it.
- **Privacy manifests** (`PrivacyInfo.xcprivacy`, issue #226): one per shipped
  bundle — see the section below. Without them App Store Connect bounces the
  upload with **ITMS-91053: Missing API declaration** before review even starts.

## Privacy manifests (`PrivacyInfo.xcprivacy`)

Apple's rule is per-bundle, not per-app: *"For each executable or dynamic library
in an app that uses a required reason API, the bundle that includes the
executable or dynamic library needs to include a privacy manifest file that
reports the API."* The watch app and both widget extensions ship as their own
bundles inside the `.ipa`, so each needs its own file.

| Bundle | File | Required-reason APIs declared |
|---|---|---|
| iOS app | `native/SendmeterNative/Resources/PrivacyInfo.xcprivacy` | UserDefaults → `CA92.1`, `1C8F.1`; SystemBootTime → `35F9.1` |
| Watch app | `ios/App/SendLogWatch Watch App/PrivacyInfo.xcprivacy` | UserDefaults → `CA92.1` + `1C8F.1`; FileTimestamp → `C617.1` |
| Watch complications extension | `ios/App/SendLogWatchWidgets/PrivacyInfo.xcprivacy` | UserDefaults → `1C8F.1` |
| Phone Live Activity extension | `native/SendmeterNative/Resources/Widgets/PrivacyInfo.xcprivacy` | UserDefaults → `1C8F.1` |

Reason codes, and why they differ per bundle:

- **`CA92.1`** — user defaults "only accessible to the app itself". Covers every
  `UserDefaults.standard` caller: `LiveActivityManager`'s pending-action queue and the watch
 `WorkoutManager`, `ForceGaugeView` and `SendLogWatchCore`'s `RPEModel`.
- **`1C8F.1`** — the App Group variant. `WidgetShared.swift` (both copies) uses
  `UserDefaults(suiteName: "group.com.jirathip.sendlog")`, which is readable by
  another bundle. CA92.1 explicitly does *not* permit "writing information that
  can be accessed by other apps", so the App Group sites need 1C8F.1 instead.
  The iOS App target has no App Group entitlement and so declares only CA92.1.
- **`C617.1`** — file metadata "inside the app container". `OfflineQueue` and
  `PendingSessionQueue` read `.creationDateKey` to drain
  `Documents/pending{,-sessions}/*.json` oldest-first. `NSPrivacyAccessedAPI`
  `CategoryFileTimestamp` is a required-reason API too, so it would have
  triggered the same ITMS-91053 mail.

The retained native targets carry their own manifests under the generated
native project inputs listed above.

**Sentry adds no manifest** (issue #227). `@sentry/react` is the *web* SDK — it
is bundled into the WebView JavaScript in `ios/App/App/public`, not linked as a
framework or dynamic library, so it is not a bundle that could carry a
`PrivacyInfo.xcprivacy` and it touches no required-reason API. Its data type
(diagnostics) is already declared on the iOS app bundle — see the Diagnostics
row below. Native crash reporting (Sentry Cocoa) is deliberately **out of
scope**; adding it later *would* add a framework bundle and require re-checking
both the manifest and this file.

`NSPrivacyCollectedDataTypes` mirrors the App Privacy table below — all six
rows on the iOS app (location is app-only: Send Conditions runs in the WebView
bundled into the main App target, not the watch app or either widget
extension); the watch app declares the subset it actually uploads (health,
fitness, user content, but never email, location, or auth diagnostics); the
two widget extensions collect nothing.

## App Store Connect: App Privacy answers ("nutrition label")

Declare these under **Data Types Collected**, all with:
- Linked to identity: **Yes** (rows are keyed to the account) — **except
  Location, which is No** (see below)
- Used for tracking: **No**
- Purpose: **App Functionality** (only)

| Data type | Category |
|---|---|
| Email address | Contact Info → Email Address |
| Health & fitness data (HR, HRV, sleep, workouts) | Health & Fitness → Health / Fitness |
| Body weight | Health & Fitness → Health |
| Training/session logs, force recordings | User Content → Other User Content |
| Error diagnostics (crash/error reports) | Diagnostics → Other Diagnostic Data |
| Location (Send Conditions weather lookup) | Location → Coarse Location |

The Location row is the one exception to the "Linked to identity: Yes" default
above: `src/lib/weather.ts` takes device coordinates from
`@capacitor/geolocation` and rounds them to 2 decimal places (~1.1km) *before*
either fetch — that rounding is why the declared sub-type is **Coarse**, not
Precise, per Apple's own threshold (Precise = 3+ decimal places). The rounded
coordinates then go to **Open-Meteo** (a third-party weather API) to fetch a
reading, and nothing ties them to the account or stores them server-side.
Answer that row **Linked to identity: No, Used for tracking: No, Purpose: App
Functionality only**.

The Diagnostics row covers error monitoring keyed to the auth uuid, which is why
it answers "linked to identity: yes" like every other row here (except Location,
above):

**Error monitoring** (issues #227 and #382) covers uncaught JavaScript
exceptions, React render errors, unhandled promise rejections, and a narrow set
of handled session/workout failures after recovery is exhausted, processed by **Sentry**
(`sentry.io`, Functional Software, Inc.), one of **two** third-party
processors the app sends anything to — the other is Open-Meteo (weather
lookups, covered by the Location row above). The typeface (Inter) is
self-hosted in the app bundle (#505), so no request goes to Google Fonts
any more. `src/lib/monitoring.ts` is the only place Sentry is configured.
(Sign in with Apple additionally makes Apple a party on that login path —
see the Sign in with Apple bullet above.)

The bounded auth-diagnostics ring remains on-device in Preferences and is not
uploaded or included in the App Privacy collected-data answers.

What Sentry receives is built from an allow-list in `beforeSend` /
`beforeBreadcrumb`, not filtered after the fact:

- **Identity is the Supabase auth uuid and nothing else** — never the email,
  username, or IP.
- **No health or fitness data, ever.** Every `HealthMetric` field name and value
  is dropped before send; `src/lib/monitoring.test.ts` asserts it on an event
  deliberately built carrying all of them.
- URLs lose their query strings; `extra`, `contexts`, `tags` and breadcrumbs
  keep only allow-listed keys (console breadcrumbs are dropped outright).
- No session replay (`replaysSessionSampleRate`/`replaysOnErrorSampleRate` = 0)
  and no performance tracing. The SDK's `dataCollection` switches are all off —
  no inferred user, no cookies, no request/response headers or bodies, no query
  params, no stack-frame local variables (that one defaults to *on* and a local
  could be a whole health record). The deprecated `sendDefaultPii` is unused.
- The SDK initializes **only** when a build-time `VITE_SENTRY_DSN` is present.
  Dev, test and any DSN-less build send nothing — the SDK is dead-code-
  eliminated from the bundle entirely.
- Handled database failures send only closed operation/class/outcome tags and
  numeric/boolean diagnostics. Raw Supabase errors, rows, notes, training or
  health values, response bodies, `details`, and `hint` are never captured.
  Recovered load/network/auth failures, expected BLE disconnects, cancellation,
  and recordings retained in the offline queue are deliberately excluded.

**Used for tracking stays "No"**: the data is never linked with third-party
data for advertising or measurement, and there is no ad network or cross-app
identifier — so **no ATT prompt** and `NSPrivacyTracking` stays `false`.

Everything else (contacts, identifiers, purchases, browsing):
**Not collected**. There are no analytics or ad SDKs and no trackers — Sentry is
error monitoring only.

## Review notes (paste into "Notes" for the reviewer)

**→ The full answer now lives in `docs/app-review-notes.md`.** App Review
rejected a submission for missing this information (2026-08), and asked for all
seven items — functionality, tested devices, audience, setup instructions,
external services, regional differences, regulated-industry status — to be in
the Notes field for *every* future submission. Paste that document, not the
short blurb below, which is kept only as the source of the privacy wording.

> Sign in with the demo account below (email + password on the login screen —
> tap "Sign in with password instead" if the magic-link form shows).
> The Tindeq tab connects to a physical Tindeq Progressor strain gauge over
> Bluetooth; without the device it shows the connect screen only.
> Health data (HRV, resting HR, respiratory rate, sleep, weight) is read on the
> iPhone with HealthKit permission — including data from any other apps/wearables
> the user has connected to Apple Health — to compute a daily recovery score. It
> is stored on the user's own account row (see privacy policy) and never used for
> advertising.
> Crash/error diagnostics are processed by Sentry (sentry.io). Reports carry the
> account's anonymous user id, the error and its stack trace, plus basic
> device/OS/app-version context and recent in-app activity (taps, in-app
> navigation, and request URLs) — health data, email and request contents are
> stripped before the report is sent, and there is no analytics, advertising,
> or tracking SDK in the app.
> Location is used only to fetch weather; coordinates are rounded to ~1km
> before being sent to Open-Meteo, never stored or linked to the account.

**Demo account**: create a throwaway user before submitting — sign up via
magic link on the web app with a spare email, set a password via Account →
Set Password, log 2–3 sessions so the reviewer sees a populated dashboard.
Put that email/password in the review notes.

## Remaining manual steps (App Store Connect / Xcode)

1. ~~Join the Apple Developer Program ($99/yr).~~ **Done.**
2. App Store Connect → New App → **one** iOS app record, bundle id
   `com.jirathip.sendlog`. The watch app is an **embedded companion**
   (`com.jirathip.sendlog.watchkitapp`) that ships inside the iOS app — it is
   **not** a separate App Store record.
   Before `native_beta` can fetch profiles, manually enable **HealthKit** and
   **App Groups** on `com.jirathip.sendlog.watchkitapp`, and **App Groups** on
   `com.jirathip.sendlog.watchkitapp.widgets`; attach
   `group.com.jirathip.sendlog` to both App IDs in Apple Developer →
   Certificates, IDs & Profiles. For signed Debug device builds, also create
   `com.jirathip.sendlog.native.watchkitapp` with **HealthKit** + **App Groups**
   and `com.jirathip.sendlog.native.watchkitapp.widgets` with **App Groups**;
   attach the same group to both Debug IDs. Unsigned simulator Debug builds do
   not need portal profiles, but code-signed Debug device builds do. Fastlane
   can register the IDs and verify the capability flags, but cannot toggle App
   Groups or attach the group container; it fails before profile fetch when the
   flags are absent.
3. Deploy the web app so the privacy-policy and support URLs are live; paste
   `https://sendmeter.app/privacy.html` under App Privacy and
   `https://sendmeter.app/support.html` under the iOS version's Support URL.
4. Fill App Privacy per the table above.
5. Review the existing App Store screenshots and reuse them by default. Replace
   them only when they no longer accurately represent the UI in the build being
   submitted; when replacement is needed, use the automation in the next section.
6. Export compliance: uses only standard TLS → answer "standard encryption,
   exempt" (France declaration auto-handled).
7. Age rating questionnaire: all "None" → 4+.
8. **Generate the privacy report** — Xcode → Product → Archive → right-click the
   archive in the Organizer → **Generate Privacy Report**. Diff the PDF against
   the App Privacy table above: the aggregated data types must match row for row,
   and the required-reason section must list UserDefaults (`CA92.1`, `1C8F.1`)
   and FileTimestamp (`C617.1`) and nothing else. This can only be done from
   Xcode on a real archive — it is not reproducible in CI.
9. Promote `staging` to `main`, wait for the Production migration workflow,
   then dispatch the TestFlight workflow from `main`. The archive uses the
   production Supabase project, so the workflow deliberately rejects
   `staging` and other refs. Select the uploaded build in App Store Connect and
   test it in TestFlight. Before submission, review `RELEASE_NOTES.md` and turn
   its **Unreleased** entries into concise, plain-language App Store **What’s New
   in This Version** copy. In `RELEASE_NOTES.md`, archive those entries under
   `## <version> — <YYYY-MM-DD>` using the release version and ISO date, then
   recreate one empty **Unreleased** section with **Added**, **Improved**, and
   **Fixed** headings. Submit the tested build for review.

For iPhone testing before promotion, use `npm run sync:local` with paired
simulators. A physical-device build cannot reach the laptop's local Supabase
stack and currently uses production; use a throwaway production account for
device-only Bluetooth, HealthKit, and signing checks.

- **Password reset email** (Settings → Account & Security → Send Password Reset
  Email): device-only — verify the reset email's link reopens the app into the
  password-recovery flow via `com.jirathip.sendlog://login-callback`. No unit
  test covers this (email/deep-link dependent).

## App Store screenshot automation

Preserve and reuse the current App Store screenshots by default. Run the
screenshot automation only when the existing images no longer accurately
represent the shipped UI; it is deliberately separate from `fastlane beta` and
every normal build:

```bash
LANG=en_US.UTF-8 bundle exec fastlane screenshots
```

The lane starts the disposable local Supabase stack, resets it from
`supabase/seed.sql`, builds/syncs a local-config Capacitor bundle, and runs two
fastlane snapshot UI-test schemes sequentially. It produces:

- four populated app screens on iPhone 17 Pro Max (6.9", 1320×2868);
- the same four screens on iPhone 13 Pro Max (6.5", 1284×2778), retained for
  the issue's explicit compatibility request even though App Store Connect can
  scale the 6.9" set down;
- the same four screens in portrait on iPad Pro 13-inch (M5, 2064×2752),
  satisfying App Store Connect's required 13-inch iPad display set;
- two real watch-app screens on Apple Watch SE 3 (40mm, 324×394) and Apple Watch
  Ultra 3 (49mm, 422×514), with deterministic readiness/ACWR fixture values
  enabled only by snapshot's launch argument; the shared fixture matrix also
  checks every essential Force control at 44pt on both sizes.

Outputs land in `fastlane/screenshots/en-US/`. The lane fails if the expected
count or pixel dimensions drift. The directory and HTML summary are gitignored:
review the PNGs locally, then upload the approved selection in App Store Connect
Media Manager. Do not commit generated screenshots; they are release artifacts,
while the UI tests, seed, and lane are the maintainable source of truth.

Prerequisites are Docker, the repository's pinned Node/Ruby dependencies, Xcode
with current iOS/watchOS simulator runtimes, and the named simulator device
types. No App Store Connect key, signing certificate, production/demo-account
credential, paired simulators, or physical Tindeq is used. The local Supabase
stack is left running for inspection; stop it with `npm run db:stop` if desired.

Reference behavior: [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/),
[Apple's upload guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/),
and [fastlane snapshot](https://docs.fastlane.tools/actions/capture_ios_screenshots/).
