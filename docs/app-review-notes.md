# App Review Information — reviewer notes

This is the canonical answer to App Review's "we need additional information"
request. Paste the **Reviewer notes** section verbatim into App Store Connect →
App Review Information → **Notes**, and keep it there for every future
submission (Apple explicitly asked for it to be present up front).

This doc now serves the **native** Sendmeter build (#617 / #474 are re-scoped
native-only; the Capacitor-era answers are superseded). The native Release
target ships to TestFlight under the shipped bundle id
`com.jirathip.sendlog` (`fastlane native_beta`, #637) and embeds the existing
`ios/App/SendLogWatch Watch App` target as
`com.jirathip.sendlog.watchkitapp`. The watch Info.plist points back to
`com.jirathip.sendlog`, so a signed Release install can pair with the phone
and use the direct WatchConnectivity live-workout mirror. The Debug-only
`com.jirathip.sendlog.native` ID is for side-by-side development and is not the
submitted binary. Physical installation, pairing, and the direct-vs-realtime
transport behavior remain device-only checks.

Two fields must be refreshed each submission before pasting:

- the **demo account** credentials (see `docs/app-store-checklist.md` →
  "Demo account"),
- the **tested devices / OS versions** list (item 2) — write down what you
  actually ran the submitted build on.

---

## Reviewer notes (paste into App Store Connect)

### 1. Demo account and how to sign in

Email: `[FILL IN — demo account email]`
Password: `[FILL IN — demo account password]`

The iPhone app opens on the password sign-in form by default. If a magic-link
form is shown instead, tap **"Sign in with password instead"** and enter the
credentials above. Sign in with Apple and passkeys are also offered but are not
needed to review the app. No code, hardware, or sample file is required to reach
any screen.

The demo account is pre-populated with several weeks of training sessions,
health metrics, and force recordings so every screen shows real data
immediately.

### 2. What the app does, and who it is for

Sendmeter is a **training tracker for rock climbers**, in particular for the
finger-strength and load-management side of climbing training.

The problem it solves: climbers accumulate finger and tendon load faster than
they can perceive it, and both overtraining injuries and under-recovery are
common. Sendmeter turns that into numbers the athlete can act on.

Core features:

- **Home** — a daily readiness/recovery score computed from Apple Health data
  (heart-rate variability, resting heart rate, respiratory rate, sleep, body
  weight), plus training-load charts (acute:chronic workload ratio, weekly and
  daily load).
- **Workout** — logging a climbing session: session type, duration, perceived
  exertion, boulder attempts. Includes a guided routine timer and a phone
  full-screen workout timer.
- **Force** — finger-strength measurement. Connects over Bluetooth to a
  **Tindeq Progressor** hand dynamometer (a commercial strain gauge sold to
  climbers) and records force-vs-time curves, max strength, critical force, and
  guided test/training protocols.
- **History** — a timeline of all past sessions and force recordings, editable
  after the fact.
- **Apple Watch companion** — the signed Release native phone app embeds the
  `com.jirathip.sendlog.watchkitapp` target. Installing the phone app installs
  the companion on a paired Apple Watch; direct WatchConnectivity behavior is
  a physical-device check.

Target audience: recreational and competitive rock climbers who train
deliberately, and coaches working with them. General audience, age rating 4+.
The app gives training information only; it makes no medical claims, offers no
diagnosis or treatment, and is not a medical device.

### 3. Permission prompts the app requests, and why

All of these appear in the screen recording. All are optional — the app is
fully usable if every one is declined.

- **Apple Health (read)** — on the iPhone, to compute the daily readiness score
  from HRV, resting heart rate, respiratory rate, sleep and body weight. The
  iPhone only reads; it never writes to Health. Requested automatically the
  first time the user signs in on the iPhone — the prompt appears immediately
  after sign-in, not behind a settings toggle.
- **Bluetooth** — to connect to the user's own Tindeq Progressor force gauge.
  Requested on the Force tab when the user taps Connect.
- **Location (when in use only)** — used *only* by the optional "Send
  Conditions" card, which shows local temperature and humidity (climbing
  friction conditions). Coordinates are rounded to ~1 km before being sent to
  the weather provider, are never stored, and are never linked to the account.
  There is no background location use.

(The embedded **Apple Watch** companion separately requests Health and Motion &
Fitness access on the paired watch; those prompts and its runtime behavior are
device-only to verify.)

There is **no App Tracking Transparency prompt**, because the app does no
tracking: it contains no advertising SDK, no analytics SDK, and no cross-app or
advertising identifier.

### 4. Accounts, purchases, and user-generated content

- **Registration and login**: email + password, email magic link, Sign in with
  Apple, or a passkey. All are shown on the login screen.
- **Account deletion in-app**: Account (the button in the bottom-right of the
  main screen) → scroll to **Danger zone** → **Delete account**. This
  permanently deletes the auth user and cascades to every row of the user's
  data. It is included in the screen recording.
- **Paid content**: none. The app has **no in-app purchases, no subscriptions,
  and no paid tier**. Every feature is available to every signed-in user.
- **User-generated content**: the only content a user creates is their own
  private training data (session notes, force recordings, custom protocol and
  routine names). **It is not shared with, visible to, or discoverable by any
  other user.** There is no social feed, no comments, no messaging, no profile
  browsing, and no public content of any kind. Database row-level security
  scopes every record to the owning account's user id, so there is no
  user-to-user surface that would require content reporting or blocking
  mechanisms.

### 5. External services, tools, and platforms used

- **Supabase** (Supabase Inc.) — authentication and the Postgres database that
  stores the user's account and training data. This is the app's backend.
- **Apple HealthKit** — source of the health metrics used for the readiness
  score (on-device, user-authorized).
- **Sign in with Apple** — one of the offered authentication methods.
- **Open-Meteo** (open-meteo.com) — public weather API, used only for the
  optional Send Conditions card, called with coordinates rounded to ~1 km.
- **Error monitoring / Sentry** — **not present in the native build.** The
  native target deliberately omits the web Sentry SDK (the Capacitor app's
  Sentry wiring is not carried forward), so the app collects no crash, error,
  or other diagnostic data, declares no Diagnostics data type in its privacy
  manifest, and this table has no Diagnostics row. The on-device auth/queue
  breadcrumbs stay on the device. If error monitoring is ever added, re-verify
  the privacy manifest and every answer in this table.
- **Tindeq Progressor** — a third-party Bluetooth force gauge the user already
  owns. The app talks to it directly over Bluetooth LE; no Tindeq server or
  account is involved, and no data is sent to Tindeq.

There are **no payment processors, no AI services, no advertising networks, no
analytics providers, and no data brokers**. Beyond the app's own Supabase
backend, **Open-Meteo is the only third-party service the app sends anything
to**; Sign in with Apple additionally makes Apple a party on that login path.

### 6. Regional differences

**There are none.** The app ships a single English-language build with
identical features, content, and pricing (free) in every region. There is no
geo-gating, no region-specific content, no regional feature flags, and no
localization variants. Weather data via Open-Meteo is available worldwide.

### 7. Regulated industries and third-party material

Sendmeter does **not** operate in a regulated industry and includes **no
protected third-party material**.

- It is a fitness/training log, not a medical or health-care app. It provides
  no diagnosis, no treatment, no medical advice, and no medical-device
  function. The readiness score is a training-guidance heuristic computed from
  the user's own Apple Health data.
- No financial, gambling, pharmaceutical, cannabis, telehealth, or similar
  regulated activity.
- All content — text, icons, artwork, protocol definitions, and code — is
  original work by the developer. The native build uses the iOS system font
  (no third-party typeface is bundled). No licensed, trademarked, or
  copyrighted third-party content is included.
- The Tindeq Progressor is hardware the user independently owns and connects to
  over standard Bluetooth; the app neither redistributes Tindeq software nor
  claims affiliation with Tindeq.

### 8. Devices and operating systems tested

`[FILL IN before each submission — for example:]`

- iPhone `[model]`, iOS `[version]` — physical device
- Additional simulators used during development: iPhone 17 Pro Max, iPhone 13
  Pro Max, iPad Pro 13-inch (M5), Apple Watch SE 3 (40 mm), Apple Watch Ultra 3
  (49 mm)

Minimum supported versions: **iOS 16.2** (the native deployment target; the
in-app Live Activity extension is non-interactive and also min 16.2). The
Release binary embeds the watch companion target; installation and
WatchConnectivity pairing are physical-device checks.

---

## Screen recording — shot list

Apple wants one recording, captured **on a physical device running the latest
OS**, starting from app launch. Record with iOS Screen Recording (Control
Centre), narrate or caption the steps, and upload it as an App Review
attachment.

Before recording: sign the demo account **out** on the device, and reset the
app's permission grants (Settings → Sendmeter → toggle off Health / Bluetooth /
Location, or delete and reinstall) so the prompts actually appear on camera.

1. **Launch** the app from the Home screen — show the icon being tapped and the
   splash/login screen appearing.
2. **Registration**: tap Sign up, create a throwaway account with an email
   address, and show it succeeding. (If magic-link email is inconvenient on
   camera, show the sign-up screen and state that the demo account will be used
   instead.)
3. **Login, and the Health permission prompt**: sign in with the demo account
   email + password. Also briefly show the Sign in with Apple and passkey
   buttons on the login screen. **The HealthKit permission sheet appears on its
   own immediately after the first successful sign-in** — it is requested
   automatically, not from a settings toggle, so keep recording through the
   sign-in and grant it on camera. Note it fires on whichever sign-in comes
   first on that install: if you completed the registration in step 2, expect
   it there instead. iOS shows it only once per install, so if you miss it the
   only way to get it back on camera is to delete and reinstall the app.
4. **Home tab**: readiness score, phase banner, ACWR and load charts. Tap into a
   detail sheet to show the explanation, and show the readiness score now
   populated from the Health data just granted.
5. **Location permission prompt**: open the Send Conditions card → show the
   location prompt → grant → show the weather reading.
6. **Workout tab**: start a session, show the timer / routine runner, log an
   attempt, then save the session.
7. **Force tab**: tap Connect → show the **Bluetooth permission prompt** →
   connect to the Tindeq Progressor and record one pull, showing the live force
   curve and the saved recording. (Do this with the real device if you have it —
   this is the feature reviewers most often cannot evaluate, and showing it
   working is the point of the recording.)
8. **Apple Watch companion**: install the signed Release build on a physical
   paired iPhone/Apple Watch to verify that the embedded
   `com.jirathip.sendlog.watchkitapp` app installs and that the live Workout
   mirror uses WatchConnectivity rather than the realtime fallback. This is
   device-only; the lock-screen Live Activity card for guided Force protocols
   (iOS 16.2+) is also in this build if you want to show it.
9. **History tab**: show the timeline of sessions and recordings, open one, and
   edit it.
10. **Account deletion**: Account → Danger zone → **Delete account** → confirm →
    show that the app returns to the logged-out login screen. Do this last, on a
    throwaway account, not on the demo account you submitted.
11. Explicitly state on camera (or in a caption) that the app has **no in-app
    purchases, no subscriptions, no paid content, and no user-to-user content**,
    so there is nothing to demonstrate for those items.
