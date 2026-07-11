# Send Log Watch — build & deploy guide

## Status (2026-07-11)

Everything below is **already done** on this Mac:

- ✅ Xcode 26.6 installed; `xcodegen` installed; project generates and builds clean.
- ✅ All 12 unit tests pass; app installs and launches in the watchOS simulator.
- ✅ Apple ID added in Xcode; development certificate created (`Apple Development: guyjrt10984@gmail.com`).
- ✅ Team `9244PWFYD7` + automatic signing set in `project.yml` — no Xcode signing UI needed, survives regeneration.
- ✅ Schema (`climb_workouts`, `climb_attempts`) applied to Supabase with RLS.

**Remaining — deploy to the physical watch** (needs the iPhone, ~10 min):

1. Plug the iPhone (paired to the watch) into this Mac with a cable → tap **Trust** on the phone.
2. On the watch: Settings → Privacy & Security → **Developer Mode** → on (watch reboots). Keep the watch on its charger.
3. Verify the device shows up: `xcrun devicectl list devices` (or Xcode → Window → Devices and Simulators).
4. Register + provision + build (first run also creates the free-tier provisioning profile):
   ```bash
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   cd watch
   xcodebuild build -project SendLogWatch.xcodeproj -scheme SendLogWatch \
     -destination 'generic/platform=watchOS' -allowProvisioningUpdates
   ```
   (This failed before with "team has no devices" — it succeeds once the phone+watch are connected. Or just press Run in Xcode with the watch selected as destination.)
5. Deploy: select the watch as run destination in Xcode → Run. First install over Wi-Fi is slow.
6. On the watch, grant Health / Motion / Bluetooth prompts.
7. In the **web app**: top-right **Watch** button → set a password. Sign in on the watch with your email + that password (one time; persists).
8. Free Apple ID: the install expires every **7 days** — rebuild to the watch weekly (step 5 only).

A standalone Apple Watch app (watchOS 10+, Series 6 or later; built for Series 9/10/Ultra):

- **Force Gauge** — connects to a Tindeq Progressor over Bluetooth, live force + peak + sparkline, tare/start/stop, saves recordings to the same Supabase tables the web app reads.
- **Climb Workout** — HealthKit workout with live heart rate; wrist motion + barometric altitude auto-detect boulder attempts. At the end you confirm boulder count and RPE (prefilled with the predicted values) and it logs an "Auto-tracked" session that feeds the web app's ACWR.

## One-time setup

### 1. Install Xcode

App Store → Xcode (this also fixes the outdated Command Line Tools that currently block Homebrew). Then:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
brew install xcodegen
```

### 2. Generate and open the project

```bash
cd watch
xcodegen generate
open SendLogWatch.xcodeproj
```

Xcode will resolve the supabase-swift package on first open.

### 3. Signing

- Select the `SendLogWatch` target → Signing & Capabilities → choose your Team (your Apple ID works).
- **Free Apple ID**: provisioning expires every 7 days (rebuild to the watch weekly) and allows max 3 sideloaded app ids. A $99/year developer account gives 1-year profiles.
- If the bundle id `com.jirathip.sendlog.SendLogWatch` is taken, let Xcode suggest a variant.

### 4. Deploy to the watch

- On the watch: Settings → Privacy & Security → Developer Mode → on (reboots the watch).
- In Xcode: Window → Devices and Simulators — the watch appears via the paired iPhone (same Wi-Fi; keep the watch on its charger for the first install, it's slow).
- Select the watch as run destination → Run.

### 5. First run on the watch

1. Grant **Health** access (heart rate, energy, workouts), **Motion & Fitness**, and **Bluetooth** when prompted.
2. **Set your watch password first**: in the web app, tap **Watch** (top right) → set a password. (Free-tier Supabase can't put sign-in codes in emails, so the watch uses email + password; web login stays magic-link.)
3. Sign in on the watch with your email + that password. You only do this once — the session persists.

## Testing without hardware

- **Simulator**: `xcodegen generate` → run on a watchOS simulator. Sign-in and database writes work (real network). Bluetooth and real sensors don't — use the unit tests:
  - `SendLogWatchTests/AttemptDetectorTests` — synthetic altitude/motion traces (clean attempt, merge, walking noise, pressure drift, short hop).
  - `SendLogWatchTests/TindeqProtocolTests` — byte-exact frames matching the web parser.
- **Web fake mode**: the web app's Tindeq tab with `?fake-tindeq` verifies the recording render path end-to-end.

## First real gym session checklist

1. Force Gauge: connect → tare → pull → stop → save → recording appears in the web Tindeq tab.
2. Climb Workout: start → climb a few problems → watch the live boulder counter → end → adjust count/RPE if needed → save.
3. Web app: the session appears in History as "Auto-tracked" and moves the ACWR dial.
4. If detection over/under-counts, the 1 Hz debug trace is stored in `climb_workouts.raw` — tune the thresholds in `SendLogWatch/Config/Tunables.swift` (all constants live there).

## Offline behavior

Workout saves are written to disk first, then uploaded; if the gym has no signal, they upload automatically next time the app opens (pending count shows on the home screen). Uploads are idempotent — no duplicates on retry.
