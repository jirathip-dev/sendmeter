# Verify recipe — Sendmeter (native iOS app in a private simulator)

The product is the SwiftUI iPhone/iPad app in `native/SendmeterNative`. There is
no web UI and no server, so `$DROVER_PORT` is used only to name this lane's
simulators. Run every block from the repo root of the checked-out head, in one
shell, in order.

Never sign in: Debug builds talk to the PRODUCTION Supabase project
(CLAUDE.md, "Environment and data boundaries"). Every screen below is reached
through a DEBUG-only launch argument that renders the real views with no
session and no backend.

Device-only (never claim from this recipe): HealthKit data, Bluetooth/Tindeq,
WatchConnectivity, Live Activities, widgets/complications, passkeys, sign-in.

## Launch

Setup: the lane folder, the sim-task wrapper, and XcodeGen at CI's pin
(`native-swift.yml` "Install XcodeGen"), fetched into the lane folder — the host
has no `xcodegen` on PATH.

```bash
export V="$DROVER_SCRATCH_TARGET/verify"
export SIMTASK="$(command -v sim-task || command -v hermes-sim-task || echo "$HOME/.hermes/profiles/fleet-impl/scripts/hermes-sim-task")"
export RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-2
export BUNDLE=com.jirathip.sendlog.native
mkdir -p "$V/shots"
curl --fail --location --silent --show-error "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip" --output "$V/xcodegen.zip"
echo "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806  $V/xcodegen.zip" | shasum --algorithm 256 --check --strict
unzip -q -o "$V/xcodegen.zip" -d "$V/xcodegen"
export PATH="$V/xcodegen/xcodegen/bin:$PATH"
```

Build the Debug simulator app (one heavy build; `drover hold` waits for a slot;
derived data must live under `$DROVER_SCRATCH_TARGET`):

```bash
just gen > "$V/gen.log" 2>&1; echo "gen=$?"
drover hold --wait 30 -- xcodebuild build -project native/SendmeterNative/SendmeterNative.xcodeproj -scheme SendmeterNative -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DROVER_SCRATCH_TARGET/dd" CODE_SIGNING_ALLOWED=NO > "$V/build.log" 2>&1; echo "build=$?"
export APP="$DROVER_SCRATCH_TARGET/dd/Build/Products/Debug-iphonesimulator/Sendmeter.app"
```

Ready signal for the build: `build=0` and `** BUILD SUCCEEDED **` as the last
line of `$V/build.log`.

Start one private simulator per width. `D` is the shot suffix: `phone` is an
iPhone 16e (390 pt wide), `tablet` an iPad Pro 13-inch (M5) (1032 pt portrait,
downscaled to 1440 px). The wrapper creates and boots the device, writes its
UDID, holds it until killed, then shuts it down and deletes only that device.

```bash
start_sim() {
  D=$1; DEV=$2
  rm -f "$V/$D.udid"
  nohup "$SIMTASK" --runtime "$RUNTIME" --device-type "$DEV" --name "verify-$DROVER_PORT-$D" --shell 'echo "$SIMULATOR_UDID" > "$V/'"$D"'.udid"; exec sleep 3600' > "$V/$D-session.log" 2>&1 &
  echo $! > "$V/$D.pid"
  until [ -s "$V/$D.udid" ] || ! kill -0 "$(cat "$V/$D.pid")" 2>/dev/null; do sleep 1; done
  U=$(cat "$V/$D.udid"); export D U
  xcrun simctl install "$U" "$APP"; echo "install=$?"
}
```

Ready signal: `$V/<D>-session.log` shows
`hermes-sim-task: running on <UDID> (verify-<port>-<D>)` and `install=0`.

Teardown (per device, after its Drive/Evidence pass):

```bash
stop_sim() {
  kill "$(cat "$V/$1.pid")"
  until ! kill -0 "$(cat "$V/$1.pid")" 2>/dev/null; do sleep 1; done
  xcrun simctl list devices | grep -c "verify-$DROVER_PORT-$1"
}
```

Teardown passes when `stop_sim` prints `0` (the device is gone). The wrapper
exits 143 (SIGTERM) — expected.

## Doctor

The installed app resolves and launches with a pid:

```bash
doctor() {
  xcrun simctl get_app_container "$U" "$BUNDLE" app; echo "doctor-container=$?"
  xcrun simctl launch --terminate-running-process "$U" "$BUNDLE"; echo "doctor-launch=$?"
}
```

Pass: both exit 0 and the launch prints `com.jirathip.sendlog.native: <pid>`.

## Drive

Each screen is one relaunch with its launch arguments, then an 8 s settle (the
splash runs for a few seconds; a shot taken earlier shows the splash, which is
a FAIL of the shot, not of the app). simctl cannot tap, so each screen is
reached by its argument, not by navigation.

```bash
shot() {
  name=$1; shift
  xcrun simctl launch --terminate-running-process "$U" "$BUNDLE" "$@" > "$V/launch-$name-$D.txt" 2>&1; rc=$?
  sleep 8
  xcrun simctl io "$U" screenshot "$V/shots/$name-$D.png" > /dev/null 2>&1; src=$?
  xcrun simctl spawn "$U" log show --last 10s --style compact --predicate 'process == "Sendmeter" AND (messageType == error OR messageType == fault)' > "$V/console-$name-$D.log" 2>&1
  echo "$name $D launch=$rc shot=$src" | tee -a "$V/transcript.txt"
}
```

The Feature map lists the `shot` line for each screen.

## Evidence

- Screenshots: `$V/shots/<screen>-<D>.png` at device pixels, then the two
  widths the reviewer reads:

  ```bash
  resample() {
    for f in "$V"/shots/*-phone.png; do sips --resampleWidth 390 "$f" --out "${f%-phone.png}-390.png" > /dev/null; done
    for f in "$V"/shots/*-tablet.png; do sips --resampleWidth 1440 "$f" --out "${f%-tablet.png}-1440.png" > /dev/null; done
  }
  ```

- Design diff: compare a `-390`/`-1440` shot against an approved one by eye,
  or with `sips -g pixelWidth -g pixelHeight` for size; `hermes-sim-task` has
  no diff mode.
- Transcript: `$V/transcript.txt` (one line per shot with its exit codes),
  `$V/launch-*.txt`, `$V/console-*.log`, `$V/build.log`,
  `$V/<D>-session.log`.
- Exit codes to record: `gen`, `build`, `install`, `doctor-container`,
  `doctor-launch`, each shot's `launch=` and `shot=`, and `stop_sim`'s count.
- Console check: every line of `$V/console-*.log` after the `Timestamp`
  header must match a Known noise bullet:

  ```bash
  console_check() {
    sed -n 's/^- `\([^`]*\)`.*/\1/p' .drover/verify.md > "$V/noise.txt"
    cat "$V"/console-*.log | grep -v '^Timestamp' | grep -v -F -f "$V/noise.txt"; echo "unknown-console-lines-exit=$?"
  }
  ```

  Pass: no lines printed and `unknown-console-lines-exit=1`.

## Known noise

Simulator-environment errors present at staging `edaa2374` on every launch, or
pre-existing on the named screen:

- `cannot add handler to 0 from 0 - dropping` — CoreAnimation, every launch.
- `WCSession is not paired` — no paired watch in the simulator.
- `WCSession has not been activated` — same.
- `failed due to WCErrorCodeDeviceNotPaired` — same.
- `dropping as pairingIDs no longer match` — same.
- `[com.apple.runtime-issues:Auth] <compose failure` — supabase-swift auth runtime warning with no session.
- `getpwuid_r did not find a match for uid` — simulator user lookup.
- `[com.apple.bluetooth:CoreBluetooth] XPC connection invalid` — no Bluetooth in the simulator.
- `can only accept this command while in the powered on state` — same.
- `com.apple.PointerUI.pointeruid.default-service` — simulator pointer service.
- `[com.apple.renderbox:error] building pipeline` — first-render shader compile time.
- `[com.apple.app_launch_measurement:General] Failed to send CA Event` — launch metrics.
- `[com.apple.activitykit:api] Updating content for activity` — Live Activities need a signed device build.
- `Charts: Falling back to a fixed dimension size for a mark` — `recovery` screen.
- `(libCoreFSCache.dylib) fopen failed for data file` — first launch on a freshly created simulator.
- `[com.apple.UIKit:TrackingElementWindowController] The tracking window controller is unable to get the keyboard scene` — iPad simulator, every screen.
- `Modifying state during view update` — `training-load` screen, pre-existing at staging.

## Feature map

Each screen → its `shot` line (DEBUG launch arguments,
`native/SendmeterNative/Sources/App/SendmeterNativeApp.swift`):

```bash
screens() {
shot signed-out
shot dashboard --tabs-fixture dashboard
shot force --tabs-fixture force
shot workout --tabs-fixture workout
shot history --tabs-fixture history
shot settings --tabs-fixture settings
shot recovery --recovery-fixture
shot workout-charts --workout-charts-fixture
shot training-load --training-load-fixture
shot guided-force --guided-force-fixture
shot manual-workout --tabs-fixture workout --manual-workout-fixture
shot error-banner --error-banner-fixture short
}
```

- Sign-in screen (signed out) → no arguments.
- Dashboard / Force / Workout / History / Settings tabs → `--tabs-fixture <tab>`.
- Recovery inputs sheet → `--recovery-fixture` (`--recovery-fixture-scrolled` scrolls it).
- Workout detail charts → `--workout-charts-fixture`.
- Training load → `--training-load-fixture` (`--training-load-delayed-fixture`, `--training-load-empty-window-fixture` for its other states).
- Guided force session cover → `--guided-force-fixture` (`-scrolled`, `-measure` variants).
- Manual workout in progress → `--tabs-fixture workout --manual-workout-fixture`.
- Error banner → `--error-banner-fixture short|long|unreadable` (add `--tabs-fixture <tab>` to raise it over a tab).
- Larger text → append `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL` to any `shot` line.

Full pass (every `bash` block of this file, top to bottom, is exactly this run):

```bash
start_sim phone com.apple.CoreSimulator.SimDeviceType.iPhone-16e
doctor
screens
stop_sim phone
start_sim tablet com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
doctor
screens
stop_sim tablet
resample
console_check
```
