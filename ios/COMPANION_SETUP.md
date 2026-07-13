# Watch companion app — architecture & setup guide

## What changed

The watch app used to be a fully standalone watchOS app (its own Xcode
project at `watch/`, own email+password login). It's now a **true
companion app**, built as a second target inside
`ios/App/App.xcodeproj` alongside the Capacitor iOS app. Signing in on
the iPhone relays the session to the watch automatically over
WatchConnectivity — no separate watch login in normal use.

`watch/` still exists as a rollback reference but is no longer the
one to build from. Don't rebuild it to a device — see "Free Apple
Developer team limits" below for why.

## How the auto-login actually works

1. `native-plugins/sendlog-auth-bridge/` — a local Capacitor plugin
   (mirrors the structure of `@capacitor-community/bluetooth-le`, the
   only other native plugin in this repo). `ios/Sources/SendLogAuthBridge/Plugin.swift`
   exposes `setSession`/`clearSession`, relayed via
   `WCSession.default.updateApplicationContext(...)`. Guards
   `WCSession.isSupported()` since the app is universal (iPad has no
   watch pairing).
2. `src/lib/watchAuthRelay.ts` calls the plugin from
   `src/hooks/useAuth.ts`'s `onAuthStateChange`, on **every** event
   that carries a session (`SIGNED_IN`/`TOKEN_REFRESHED`/`USER_UPDATED`)
   — not just initial sign-in, since Supabase refresh tokens are
   single-use/rotating.
3. On the watch, `ios/App/SendLogWatch Watch App/Services/AuthManager.swift`
   implements `WCSessionDelegate`. At launch it reads
   `WCSession.default.receivedApplicationContext` **synchronously**
   (not just the `didReceiveApplicationContext` delegate callback,
   which only fires for context received *after* that point — a cold
   watch launch would otherwise miss data already queued), decodes an
   explicit `{"event": "signedIn"|"signedOut", ...}` payload, and
   calls `client.auth.setSession(accessToken:refreshToken:)` to
   hydrate. **This makes a network call** (verified against
   supabase-swift source — it validates/refreshes the token against
   Supabase, it's not purely local), so the watch needs connectivity
   the first time it hydrates, same as a normal login would.
4. Falls back to the existing Keychain session, then to manual
   `SignInView` (unchanged, still works standalone) if the relay
   hasn't delivered yet.

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
- Max **3 sideloaded app IDs** at a time. This project now uses 2
  (`com.jirathip.sendlog`, `com.jirathip.sendlog.watchkitapp`) via the
  companion target. **Don't also rebuild the old standalone**
  `watch/SendLogWatch.xcodeproj` (`com.jirathip.sendlog.SendLogWatch`)
  **to a device** — that would use the 3rd slot concurrently for no
  reason, since it's being retired.
- Device registration also has a cap (exact number unconfirmed) —
  if you hit it while adding another person's devices, that's the
  point where a paid membership becomes the practical unblock.

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
