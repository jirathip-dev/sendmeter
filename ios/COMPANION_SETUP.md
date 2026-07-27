# Watch companion app — architecture & setup guide

## What changed

The watch app used to be a fully standalone watchOS app (its own Xcode
project at `watch/`, own email+password login). It's now a **true
companion app**, built as a second target inside
`ios/App/App.xcodeproj` alongside the Capacitor iOS app. Signing in on
the iPhone relays the session to the watch automatically over
WatchConnectivity — and since #265 there is no separate watch login at
all: the relay carries a short-lived **access token only**, so the watch
has nothing to sign in *with* and can never hold a refresh token whose
rotation the phone owns. A watch with an expired token asks the phone
(`requestSession`) and waits.

The old standalone project at `watch/` has been deleted — every Swift
file in it was confirmed byte-identical to the companion target before
removal (except `AuthManager.swift`, which legitimately grew to add the
WatchConnectivity relay), and its 5 test files were ported into a new
`SendLogWatchTests` target in `ios/App/App.xcodeproj` first, so no test
coverage was lost. Run them with `xcodebuild test -project
ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" -only-testing:SendLogWatchTests`.

## How the auto-login actually works

1. `native-plugins/sendlog-auth-bridge/` — a local Capacitor plugin
   (mirrors the structure of `@capacitor-community/bluetooth-le`, the
   only other native plugin in this repo). `ios/Sources/SendLogAuthBridge/Plugin.swift`
   exposes `setSession`/`clearSession`, relayed via
   `WCSession.default.updateApplicationContext(...)`. Guards
   `WCSession.isSupported()` since the app is universal (iPad has no
   watch pairing). Since #265 `setSession` takes an **access token
   only** — no `refreshToken` field exists on the contract — and stamps
   every payload with a fresh `relayId`, because WatchConnectivity does
   not deliver an application context identical to the one already set.
2. `src/lib/watchAuthRelay.ts` calls the plugin from
   `src/hooks/useAuth.ts`'s `onAuthStateChange`, on **every** event
   that carries a session (`SIGNED_IN`/`TOKEN_REFRESHED`/`USER_UPDATED`)
   and on every foreground — access tokens last an hour and the watch
   cannot renew one itself.
3. On the watch, `ios/App/SendLogWatch Watch App/Services/AuthManager.swift`
   implements `WCSessionDelegate`. At launch it reads
   `WCSession.default.receivedApplicationContext` **synchronously**
   (not just the `didReceiveApplicationContext` delegate callback,
   which only fires for context received *after* that point — a cold
   watch launch would otherwise miss data already queued) and decodes an
   explicit `{"event": "signedIn"|"signedOut", ...}` payload through
   `SessionRelay` (SendLogWatchCore). Hydration is now **purely local**:
   `sub`/`exp` are read out of the JWT and the token is stored in
   `WatchSessionStore`'s own Keychain entry. There is no `AuthClient` on
   the watch at all, so nothing here can refresh, rotate or spend a
   credential — and no `GET /user` round-trip is spent per relay, which
   is what the old `auth.setSession` cost.
4. Falls back to the stored token. There is **no manual sign-in** — an
   access-token-only watch has nothing to sign in with. A watch without a
   usable token shows `WaitingForPhoneView`, which explains what it is
   waiting for and why the last relay was refused, and re-asks the phone
   (`requestSession`) on launch, on reachability, on foreground, on
   Retry, and from a slow poll.

**The relay only fires when the phone app's JS actually runs.** If
you reinstall/rebuild and the phone app was already idle from before,
force-quit and reopen it on the phone (and the watch app) to
re-trigger the relay + re-check for it.

## One-time setup on a new Mac

1. **Xcode** — same major version this was built with (26.6 at time
   of writing); an older Xcode may not have the watchOS SDK this
   project's simulators expect, though the watch target's actual
   deployment floor is watchOS 10.0 (see below), so the *device*
   compatibility is broad even if the *build machine* needs a
   reasonably current Xcode.
2. **Node** — via nvm, matching the version already used elsewhere in
   this repo (`export PATH="$HOME/.nvm/versions/node/vX.X.X/bin:$PATH"`
   — check your nvm install for the exact version; default system
   `node` is too old for Vite 8).
3. Clone the repo, `npm install` (this also symlinks the local
   `sendlog-auth-bridge` plugin via its `file:` dependency — no extra
   step needed).
4. `npm run build && npm run sync` — builds the web app and runs
   `cap sync ios`, which copies the web build into `ios/App/App/public`
   and regenerates `ios/App/CapApp-SPM/Package.swift` (auto-wires both
   native plugins; this file is Capacitor-CLI-managed, never hand-edit
   it).
5. Open `ios/App/App.xcodeproj` in Xcode.
6. **Signing, both targets** — select the **App** target →
   Signing & Capabilities → set your Team. Repeat for the
   **SendLogWatch Watch App** target. Both must use the *same* team
   for the companion embedding to sign correctly. (The committed
   project currently hardcodes team `9244PWFYD7` — you'll need to
   change this to your own team in both targets' build settings if
   you're not using that same Apple ID/team.)
7. Real-device deploy: see the troubleshooting playbook below — it's
   long enough to warrant its own section, since almost every step of
   it produces a distinct, differently-worded error the first time
   through.

## Real-device deploy — troubleshooting playbook

This is the actual sequence of errors encountered getting this
working the first time, in order, since each one looks unrelated to
the last if you don't know they're all part of the same chain.

**1. "Signing for 'App' requires a development team."**
The `App` target had no team set (only the watch target did, since
that one came from the old project.yml which committed it). Set the
team on **both** targets — see step 6 above.

**2. "Communication with Apple failed: Your team has no devices from
which to generate a provisioning profile" / "No profiles for
'com.jirathip.sendlog.watchkitapp' were found."**
The device (iPhone and/or Watch) isn't registered with your Apple
Developer account yet. Fix:
- Connect the iPhone via USB, unlock it, tap **Trust** when prompted.
- On the Watch: Settings → Privacy & Security → **Developer Mode** →
  on (it reboots).
- Window → Devices and Simulators (⇧⌘2) in Xcode — both devices
  should appear; select each and use **"Use for Development"** if
  offered.
- Retry the build (Signing & Capabilities panel → "Try Again", or
  just hit Run again).

**3. Watch doesn't show up in Devices and Simulators at all.**
It appears *through* the paired iPhone, not via its own connection —
the iPhone needs to be actively connected to Xcode first. Both
devices need to be on the **same Wi-Fi network** (Bluetooth pairing
between watch and phone isn't sufficient for Xcode's discovery — it
needs the Wi-Fi path). Unplug/replug the iPhone's cable or reopen the
Devices and Simulators window to force a re-scan.

**4. Watch listed but "Unavailable" — "previously reported a
preparation error, will try to reconnect on demand."**
A stuck local pairing/prep state. **Restart the Watch itself**
(hold side button → Power Off → hold side button again). This is the
single most effective fix for this specific state. Also worth
explicitly clicking the watch entry in the device list first — that
click is what actually triggers the "reconnect on demand."

**5. `xcodebuild -destination` lists the watch as "Ineligible" —
"doesn't have a known architecture."**
Different from #2/#4 — this means Xcode hasn't finished its own
background **device-preparation** pass (downloading device-support
files, doing the full capability/architecture handshake). This is
Xcode-GUI-only; the CLI can't force it. Open Devices and Simulators,
select the watch, and just wait — can take several minutes,
especially the first time for a given watchOS version. Keep the watch
**unlocked and physically near the Mac** during this (a locked watch
or a weak connection stalls it — the exact next error message says
this explicitly: *"may need to be unlocked to recover from previously
reported preparation errors. Ensure the device is unlocked and near
this Mac for better connection quality."*).

**6. Build succeeds (real "iOS Team Provisioning Profile" shown in
the signing log for both `com.jirathip.sendlog` and
`com.jirathip.sendlog.watchkitapp`) but the watch app never appears
on the watch.**
`xcodebuild build` compiles and signs but doesn't necessarily push the
install through — and even automatic companion-app delivery (the
normal OS mechanism for getting a watch app onto a paired watch once
it's embedded in the phone app) can be slow or unreliable for
dev-signed (non-App-Store) builds. Fastest fix, install both
explicitly via CLI once you have a successful build:
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun devicectl list devices   # get device identifiers (00008301-... format for xcodebuild -destination, a different UUID format for devicectl itself — devicectl list devices shows the one devicectl wants)

# Phone:
xcrun devicectl device install app --device <iphone-devicectl-id> \
  "$(find ~/Library/Developer/Xcode/DerivedData/App-*/Build/Products/Debug-iphoneos -maxdepth 1 -name 'App.app')"

# Watch:
xcrun devicectl device install app --device <watch-devicectl-id> \
  "$(find ~/Library/Developer/Xcode/DerivedData/App-*/Build/Products/Debug-watchos -maxdepth 1 -name 'SendLogWatch Watch App.app')"
```
Note `xcodebuild -destination id=...` wants the `00008301-...`-style
identifier (shown in Xcode's own destination-picker error messages),
while `xcrun devicectl` commands want the UUID-style identifier from
`devicectl list devices` — they are *different ID formats for the
same device*, easy to mix up.

**7. Watch app installs and launches, but shows the manual
`SignInView` instead of auto-signing-in.**
See "How the auto-login actually works" above — the relay is
event-driven, not automatic-on-install. Force-quit and reopen the
phone app (re-triggers the relay), then force-quit and reopen the
watch app (re-checks for it).

## Free Apple Developer team limits

- Provisioning profiles expire every **7 days** — rebuild to the
  device weekly. A $99/year paid membership gives 1-year profiles.
- Max **3 sideloaded app IDs** at a time. This project uses 2
  (`com.jirathip.sendlog`, `com.jirathip.sendlog.watchkitapp`) via the
  companion target.
- Device registration also has a cap (exact number unconfirmed) —
  if you hit it while adding another person's devices, that's the
  point where a paid membership becomes the practical unblock.

## Why the archive signs manually (issue #263)

**Symptom.** `fastlane beta` on CI intermittently failed at the archive
step, and the developer account kept accumulating Apple Development
certificates named *"Created via API"* — one per CI run — until it hit
Apple's per-team cap and every subsequent run failed. Because a run
only fails once the account is *at* the cap, re-running after a manual
revoke "fixed" it, which is what made this look intermittent rather
than a leak on every single run.

**Mechanism.** `build_app` (gym) issues *two* `xcodebuild`
invocations — `archive`, then `-exportArchive`. Three things that
looked like they covered signing each cover only part of it:

| Guard | Covers | Doesn't cover |
| --- | --- | --- |
| `if ENV["CI"]` cert import | Distribution certs (correctly — none leaked) | anything about *Development* certs |
| `export_options: signingStyle: "manual"` | the export invocation | the archive invocation |
| `project.pbxproj` | the archive | — but every target there is `CODE_SIGN_STYLE = Automatic` |

So the archive ran with automatic signing against a fresh runner
keychain that held only the imported *Distribution* cert. Automatic
signing wants a Development identity, found none, and — because the
lane passed `-authenticationKeyID/-IssuerID/-Path` plus
`-allowProvisioningUpdates` through `xcargs`, which gym applies to the
archive — was **authorised to create one**. It did, every run.

There is no team mismatch involved: the distribution cert is
`Apple Distribution: JIRATHIP KUNKANJANATHORN (9244PWFYD7)`, matching
the project's `DEVELOPMENT_TEAM`. `SH947DTWM4` is only the exported
p12's filename.

**Fix.** Two independent guards, in `fastlane/Fastfile`:

1. Before `build_app`, flip the *Release* configuration of the four
   archived targets (`App`, `SendLogWatch Watch App`,
   `SendmeterWidgets`, `SendLogWatchWidgets`) to `CODE_SIGN_STYLE =
   Manual`, `CODE_SIGN_IDENTITY = "Apple Distribution"` and the
   `PROVISIONING_PROFILE_SPECIFIER` that `get_provisioning_profile`
   just returned via `SharedValues::SIGH_NAME`. The archive now signs
   with material the lane already has, so there is nothing left for
   `xcodebuild` to create.
2. Move the auth flags from `xcargs` to `export_xcargs`, so the archive
   no longer receives `-allowProvisioningUpdates` at all. Even if a
   target's signing settings ever drift back to Automatic, the worst
   case becomes a loud failure instead of a silent certificate.

**Why the edit is applied at lane runtime and reverted afterwards,
rather than committed:**

- The committed project has to stay `Automatic`, or local Xcode
  development — which signs against a *personal* Apple Development team
  (`ZY74K2NK8Z`), not `9244PWFYD7` — stops building. Only the Release
  configs are touched, and only for the duration of the archive; an
  `ensure` block restores `project.pbxproj` byte-for-byte even if the
  build fails.
- Profile names are whatever sigh produced on this run. A hardcoded
  `PROVISIONING_PROFILE_SPECIFIER` in the pbxproj silently goes stale
  the first time a profile comes back under a different name.
- `xcargs` alone cannot express this: a command-line build setting
  applies to *every* target, and these four need four *different*
  profiles. There is no per-target form.

**The check that actually proves it.** A green run does not, on its
own — a run only exercises the failure when the account is at its cap.
The durable proof is negative: after a successful CI run, Certificates,
IDs & Profiles should contain **no new "Created via API" Apple
Development certificate**. Check that, not the build's exit code.

## Other decisions worth knowing about

- **`WATCHOS_DEPLOYMENT_TARGET` is 10.0**, not whatever Xcode's wizard
  defaults new targets to (it defaulted to the exact SDK version
  bundled with the installed Xcode, e.g. 26.5) — deliberately lowered
  to match the old standalone project's proven-working floor, since
  nothing in this ported code needs a newer OS. Broadens real-device
  compatibility significantly and avoids point-release mismatches.
- **`ios.scrollEnabled: false`** in `capacitor.config.ts` — disables
  WKWebView's native outer bounce/rubber-band scroll (the topbar and
  bottom nav were draggable, and the page could pan slightly
  horizontally too). `overflow: hidden` on `html`/`body` in
  `src/index.css` does *not* by itself stop this — that CSS only
  prevents content overflow, not the native `UIScrollView`'s own pan
  gesture. The app already does its own internal scrolling via
  `.content-area`, a separate nested WebKit scroller unaffected by
  this setting.
- **Physical `Info.plist`, not `GENERATE_INFOPLIST_FILE`** for the
  watch target, and it lives *outside* the target's synchronized
  source folder (`ios/App/SendLogWatch Watch App-Info.plist`, not
  inside `ios/App/SendLogWatch Watch App/`). Putting it inside causes
  Xcode's `PBXFileSystemSynchronizedRootGroup` mechanism to also
  auto-add it as a Copy Bundle Resources item, which then collides
  with the explicit Info.plist processing ("Multiple commands produce
  ... Info.plist"). This was needed to avoid guessing at
  `INFOPLIST_KEY_*` array-syntax for `WKBackgroundModes`
  (`workout-processing`) — safer to use a real plist than risk a
  silently-wrong array encoding.
- **`WKCompanionAppBundleIdentifier`** and the watch target's
  `PRODUCT_BUNDLE_IDENTIFIER` were both left broken/blank by Xcode's
  own "Watch App for Existing iOS App" wizard flow — had to be set
  explicitly (`com.jirathip.sendlog` and
  `com.jirathip.sendlog.watchkitapp` respectively). The "Embed Watch
  Content" build phase on the `App` target was *also* missing after
  the same wizard flow and had to be added manually via App target →
  General → "Frameworks, Libraries, and Embedded Content" → "+" →
  select `SendLogWatch Watch App.app`.

## iPhone health sync (HealthKit ingestion on the phone)

The iPhone app — not the watch — now reads daily HealthKit metrics
(HRV, resting HR, sleep, respiratory rate, body mass), computes the
readiness score, and writes `health_metrics`. The watch only reads the
latest score back for display (`ReadinessManager` → `Repo.fetchLatestHealthMetric`).
This captures third-party wearables (Oura/Garmin/etc.) that write to
the iPhone's merged HealthKit store — the watch's local store doesn't
see them. See the plan file's "Part 3" for the full rationale.

Architecture:
- `native-plugins/sendlog-health-core/` — pure-Swift package (Foundation
  only): `RecoveryEngine`, `RecoveryTunables`, the readiness models, and
  `Acwr`. No HealthKit/Supabase/Capacitor, so its tests run on the host:
  `cd native-plugins/sendlog-health-core && swift test` (12 tests).
- `native-plugins/sendlog-health/` — the Capacitor plugin (`SendLogHealth`):
  `HealthKitReader` (night-window `HKSampleQuery`s), `HealthSyncManager`
  (its own Supabase client, ACWR from sessions, upsert, `HKObserverQuery`
  + `enableBackgroundDelivery(.daily)`, clear+resync), `Plugin.swift`.
  The web layer drives it from `src/lib/healthSync.ts`, wired into
  `src/hooks/useAuth.ts` (session relay + `startBackgroundSync` after
  sign-in) and the Account sheet's "Clear & resync".

Build notes:
- **Minimum iOS is 16.0** (project + App target deployment target). The
  Supabase Swift SDK floors at iOS 16; Capacitor derives the CapApp-SPM
  package platform from the pbxproj `IPHONEOS_DEPLOYMENT_TARGET` (first
  occurrence — the *project-level* setting, not just the target), so that
  had to be 16 for `cap sync` to regenerate CapApp-SPM at `.iOS(.v16)`.
- The App target has HealthKit + Background Delivery entitlements
  (`ios/App/App/App.entitlements`) and `NSHealthShareUsageDescription`
  in its Info.plist. In Xcode, confirm the **HealthKit** capability (with
  **Background Delivery** checked) is present on the App target under
  Signing & Capabilities — automatic signing needs it in the provisioning
  profile, so a first device build must be done with a signed configuration
  (the CI compile-check uses `CODE_SIGNING_ALLOWED=NO`).

**Device-test checklist** (none of this is verifiable in the simulator —
HealthKit has no real HRV/sleep data there and background delivery needs
a real device):
1. `npm run build && npm run sync`, open `ios/App/App.xcodeproj`, select
   the App target → Signing & Capabilities → set your Team; confirm the
   HealthKit + Background Delivery capability is listed.
2. Run to a physical iPhone that has real Health data (ideally with a
   third-party wearable's app also writing to Health, e.g. Oura).
3. On first launch after sign-in, grant the HealthKit permission sheet.
   Confirm a `health_metrics` row appears in Supabase for today with a
   non-null `readiness`, and that the numbers reflect the *merged* store
   (i.e. include the third-party source, not just Apple Watch).
4. On the paired watch, open the app → the readiness card shows the
   iPhone-computed score ("Synced <date>"), not a locally-computed one.
5. Background delivery: with the app backgrounded, let new Health data
   land (or use Xcode's Debug → Simulate Background Fetch analog for
   HealthKit observers) and confirm the row updates without opening the
   app.
6. Account → "Clear health data & resync": confirm the rows delete, the
   web dashboard cards empty via realtime, then repopulate after the
   native `syncNow()` re-ingests.
