# App Store submission checklist (Send Log iOS + Send Log Watch)

Everything code-side is done in this repo. This file is the copy-paste guide
for the App Store Connect forms.

## Already handled in the repo ✅

- **App icons**: generated from `scripts/icon.svg` via `node scripts/generate-icons.mjs`
  into the iOS asset catalog, watch asset catalog, and PWA icons. Opaque (no alpha),
  as the 1024px marketing icon requires.
- **Privacy policy page**: `public/privacy.html` → will be live at
  `https://<your-domain>/privacy.html` once the web app deploys. That URL goes in
  App Store Connect → App Privacy → Privacy Policy URL.
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
| Auth diagnostics (null-session cause, timestamps, app build) | Diagnostics → Other Diagnostic Data |

The auth-diagnostics row is `supabase/migrations/20260726090000_auth_events.sql`
(the columns are exactly what is collected) written by `src/lib/authEventFlush.ts`
— a per-account record of why a sign-in session went away, keyed to `user_id`,
which is why it answers "linked to identity: yes" like every other row here.

Everything else (location, contacts, identifiers, purchases, browsing):
**Not collected**. There are no analytics, ads, or trackers.

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
3. Deploy the web app so the privacy-policy URL is live; paste the URL.
4. Fill App Privacy per the table above.
5. Screenshots: iPhone 6.9" and 6.5" (simulator screenshots fine), watch
   screenshots from the watch simulator (`xcrun simctl io ... screenshot`).
6. Export compliance: uses only standard TLS → answer "standard encryption,
   exempt" (France declaration auto-handled).
7. Age rating questionnaire: all "None" → 4+.
8. **Generate the privacy report** — Xcode → Product → Archive → right-click the
   archive in the Organizer → **Generate Privacy Report**. Diff the PDF against
   the App Privacy table above: the aggregated data types must match row for row,
   and the required-reason section must list UserDefaults (`CA92.1`, `1C8F.1`)
   and FileTimestamp (`C617.1`) and nothing else. This can only be done from
   Xcode on a real archive — it is not reproducible in CI.
9. Xcode → Archive → Distribute (per app) → TestFlight first, then Submit.
