# Send Log Watch — build & deploy guide

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
