# App Store submission checklist (Sendmeter iOS + Sendmeter Watch)

Everything code-side is done in this repo. This file is the copy-paste guide
for the App Store Connect forms.

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
- **Usage strings**: Bluetooth (iOS + watch), HealthKit share/read, Motion — all set.
- **No Sign in with Apple requirement**: only email-based auth, no third-party login.
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
| iOS app | `ios/App/App/PrivacyInfo.xcprivacy` | UserDefaults → `CA92.1` |
| Watch app | `ios/App/SendLogWatch Watch App/PrivacyInfo.xcprivacy` | UserDefaults → `CA92.1` + `1C8F.1`; FileTimestamp → `C617.1` |
| Watch complications extension | `ios/App/SendLogWatchWidgets/PrivacyInfo.xcprivacy` | UserDefaults → `1C8F.1` |
| Phone Live Activity extension | `ios/App/SendmeterWidgets/PrivacyInfo.xcprivacy` | none (uses no required-reason API) |

Reason codes, and why they differ per bundle:

- **`CA92.1`** — user defaults "only accessible to the app itself". Covers every
  `UserDefaults.standard` caller: `LiveActivityManager`'s pending-action queue
  (linked into the App from `native-plugins/sendlog-live-activity`),
  `@capacitor/preferences`, and on the watch `WorkoutManager`, `ForceGaugeView`
  and `SendLogWatchCore`'s `RPEModel`.
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

Nothing upstream covers any of this: `@capacitor/ios` ships a manifest with an
**empty** `NSPrivacyAccessedAPITypes` array, and `@capacitor/preferences` 8.0.1
ships no manifest at all.

**Sentry adds no manifest** (issue #227). `@sentry/react` is the *web* SDK — it
is bundled into the WebView JavaScript in `ios/App/App/public`, not linked as a
framework or dynamic library, so it is not a bundle that could carry a
`PrivacyInfo.xcprivacy` and it touches no required-reason API. Its data type
(diagnostics) is already declared on the iOS app bundle — see the Diagnostics
row below. Native crash reporting (Sentry Cocoa) is deliberately **out of
scope**; adding it later *would* add a framework bundle and require re-checking
both the manifest and this file.

`NSPrivacyCollectedDataTypes` mirrors the App Privacy table below — all four
rows on the iOS app; the watch app declares the subset it actually uploads
(health, fitness, user content, but never email or auth diagnostics); the two
widget extensions collect nothing.

## App Store Connect: App Privacy answers ("nutrition label")

Declare these under **Data Types Collected**, all with:
- Linked to identity: **Yes** (rows are keyed to the account)
- Used for tracking: **No**
- Purpose: **App Functionality** (only)

| Data type | Category |
|---|---|
| Email address | Contact Info → Email Address |
| Health & fitness data (HR, HRV, sleep, workouts) | Health & Fitness → Health / Fitness |
| Body weight | Health & Fitness → Health |
| Training/session logs, force recordings | User Content → Other User Content |
| Error diagnostics (crash/error reports) | Diagnostics → Other Diagnostic Data |

The Diagnostics row covers error monitoring keyed to the auth uuid, which is why
it answers "linked to identity: yes" like every other row here:

**Error monitoring** (issues #227 and #382) covers uncaught JavaScript
exceptions, React render errors, unhandled promise rejections, and a narrow set
of handled session/workout failures after recovery is exhausted, processed by **Sentry**
(`sentry.io`, Functional Software, Inc.) — the one **third-party processor**
the app uses. `src/lib/monitoring.ts` is the only place it is configured.

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

Everything else (location, contacts, identifiers, purchases, browsing):
**Not collected**. There are no analytics or ad SDKs and no trackers — Sentry is
error monitoring only.

## Review notes (paste into "Notes" for the reviewer)

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
> account's anonymous user id, the error and its stack trace only — health data,
> email and request contents are stripped before the report is sent, and there
> is no analytics, advertising, or tracking SDK in the app.

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
3. Deploy the web app so the privacy-policy and support URLs are live; paste
   `https://sendmeter.app/privacy.html` under App Privacy and
   `https://sendmeter.app/support.html` under the iOS version's Support URL.
4. Fill App Privacy per the table above.
5. ~~Capture iPhone + watch screenshots.~~ **Automated:** see the next section.
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
   `staging` and other refs. Select the uploaded build in App Store Connect,
   test it in TestFlight, then submit it for review.

For iPhone testing before promotion, use `npm run sync:local` with paired
simulators. A physical-device build cannot reach the laptop's local Supabase
stack and currently uses production; use a throwaway production account for
device-only Bluetooth, HealthKit, and signing checks.

## App Store screenshot automation

Run screenshots only for a release or after a meaningful UI change; this is
deliberately separate from `fastlane beta` and every normal build:

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
- two real watch-app screens on Apple Watch Ultra 3 (422×514), with deterministic
  readiness/ACWR fixture values enabled only by snapshot's launch argument.

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
