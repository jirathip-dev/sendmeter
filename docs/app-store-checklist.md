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
8. Xcode → Archive → Distribute (per app) → TestFlight first, then Submit.
