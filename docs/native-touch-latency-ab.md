# Native touch-latency A/B and scroll-safe checkpoint (#816)

This revision includes the bounded production fix and the diagnostic arms. The
normal app path uses native Button action/press recognition for implicit
buttons and a `TapGesture` for explicit tap surfaces; it does not install a
global `DragGesture(minimumDistance: 0)`. This lets a vertical scroll win
without removing the structural haptic vocabulary. Physical-device and
Release/TestFlight results remain unverified.

## Diagnostic variants

The production path is `Default` and has no banner. The DEBUG-only arms retain
the legacy zero-distance attachment solely so the same source revision can
answer the original structural-haptics question. A is deliberately labelled
as a legacy control, not as the fixed production path.

| Variant | Launch value | Root legacy attachment | Explicit legacy attachment | Direct action haptics / behavior |
| --- | --- | --- | --- | --- |
| Default | no argument | scroll-safe native Button action/press path | scroll-safe `TapGesture` path | unchanged |
| A | `A` | ON, faithful legacy control | ON, faithful legacy control | unchanged; banner says legacy control |
| B | `B` | OFF; stock button behavior | ON; explicit legacy paths remain | unchanged; banner says root gesture OFF |
| B′ | `b-prime` | ON; legacy root path remains | OFF; attachment is removed | unchanged; banner says explicit gesture OFF |
| B+B′ | `b-plus-prime` | OFF | OFF | unchanged; banner says all legacy gestures OFF |

B is the root-only arm required by the issue. B′ is necessary because this
source has explicit `.hapticTap` / `.hapticButtonStyle` paths on the reported
card/row surfaces. B+B′ is the combined legacy all-off arm when the test needs
to prove that no old structural gesture attachment remains. Direct
`Haptics.shared.play(...)` and `playGesture(...)` calls are not disabled by
these arms.

The resolver and legacy attachment are behind the app's DEBUG path. Release
and TestFlight always use the unlabelled scroll-safe Default path, regardless
of launch arguments. A, B, B′, and B+B′ show a red, non-interactive banner;
the banner is laid out below any ErrorBanner so it cannot cover its message or
dismiss button. ErrorBanner and AppToast retain bounded content shapes.

## Copy-paste physical-device procedure

Use a connected physical iPhone, a development team that can sign the native
Debug app, Xcode with the iOS SDK, and XcodeGen 2.40 or newer. Use a
throwaway/test account because this native Debug build uses the hosted
Supabase configuration. Keep the checkout at the exact source commit captured
below; do not switch branches or edit files between arms.

```bash
export SENDMETER_REPO_ROOT="$(git rev-parse --show-toplevel)"
export SENDMETER_SOURCE_SHA="$(git rev-parse HEAD)"
test -z "$(git status --porcelain)"
git rev-parse --verify "${SENDMETER_SOURCE_SHA}^{commit}"
xcrun devicectl list devices
export DEVICE_UDID="<physical-iPhone-UDID>"
export NATIVE_DERIVED_DATA="$(mktemp -d /tmp/sendmeter-native-816.XXXXXX)"

cd "$SENDMETER_REPO_ROOT/native/SendmeterNative"
xcodegen generate
xcodebuild \
  -project SendmeterNative.xcodeproj \
  -scheme SendmeterNative \
  -configuration Debug \
  -destination "id=$DEVICE_UDID" \
  -derivedDataPath "$NATIVE_DERIVED_DATA" \
  -allowProvisioningUpdates \
  build

xcrun devicectl device install app \
  --device "$DEVICE_UDID" \
  "$NATIVE_DERIVED_DATA/Build/Products/Debug-iphoneos/Sendmeter.app"
```

Primary launch route: in Xcode, open the generated project, choose the
`SendmeterNative` scheme, then add two separate entries under **Run →
Arguments Passed On Launch**:

```text
-sendmeter-structural-haptics
A
```

Use the same two entries with `B`, `b-prime`, or `b-plus-prime`. Stop and
relaunch between arms, confirm the matching red banner, and keep A/B on the
same installed binary and data state. If using `devicectl` instead, the
trailing `--` separates its options from the app arguments:

```bash
xcrun devicectl device process launch \
  --device "$DEVICE_UDID" \
  --terminate-existing \
  com.jirathip.sendlog.native \
  -- -sendmeter-structural-haptics A

xcrun devicectl device process launch \
  --device "$DEVICE_UDID" \
  --terminate-existing \
  com.jirathip.sendlog.native \
  -- -sendmeter-structural-haptics B
```

Use `b-prime` only when B is inconclusive; use `b-plus-prime` to exercise the
combined legacy all-off arm. A physical Progressor is required for the live
Progressor row. A missing device or a simulator run is not a physical result.

## Three-trial matrix

Run three comparable trials for A and B. Record B′ and B+B′ only when B is
inconclusive or when the explicit-vs-root distinction is needed. Count every
physical haptic you perceive; do not infer a haptic from source, logs, or a
simulator.

| Surface / state | Actions to exercise | Record |
| --- | --- | --- |
| Dashboard | Scroll from blank space, a row, and a card; tap cards/buttons; open/dismiss charts and sheets; exercise NavigationLinks | first-motion latency; missed/duplicate actions; haptic count |
| Workout | Scroll blank space and rows/cards; tap buttons and NavigationLinks; open/close routine/workout sheets; repeat a first-motion gesture | first-motion latency; missed/duplicate actions; haptic count |
| History | Scroll blank space, rows, and cards; scrub HR/effort/force charts; multi-select; open sheets; use NavigationLinks and buttons | first-motion latency; missed/duplicate actions; haptic count |
| Settings | Scroll blank space and rows; tap cards/buttons; open/dismiss sheets and alerts; use NavigationLinks; include ErrorBanner/AppToast when available | first-motion latency; missed/duplicate actions; haptic count; overlay bounds |
| Force, no live Progressor | Scroll blank space and cards; open charts/sheets; tap controls, rows, and NavigationLinks; trigger refused/disabled paths | first-motion latency; missed/duplicate actions; haptic count |
| Force, live Progressor | Connect a real Progressor; repeat blank-space/card/button/row starts while the live surface updates; scrub charts; open sheets and NavigationLinks | first-motion latency; missed/duplicate actions; haptic count; connection/stream state |

For every surface include one scroll beginning on blank content, one on a
row/card, and one control/button tap. For charts record a scrub and a
transition into/out of the chart. For sheets and NavigationLinks record
presentation and dismissal/back navigation. Confirm ErrorBanner/AppToast
controls remain inside their visible shapes.

## Evidence template

```text
Issue: #816
Source revision / commit (exact SENDMETER_SOURCE_SHA):
Device model:
iOS version:
Native DEBUG app build / bundle ID:
Progressor firmware/model (or “not connected”):
Tester / date / local time:

Variant: A / B / B′ / B+B′
Banner observed exactly:
Data/account state held constant: yes / no (explain)

Surface: Dashboard / Workout / History / Settings / Force-no-Progressor / Force-live-Progressor
Trial: 1 / 2 / 3
Starting screen/state:
Interaction (blank space / row / card / button / chart / sheet / NavigationLink):
First-motion latency (qualitative or measured):
Missed actions:
Duplicate actions:
Haptic count:
ErrorBanner/AppToast stayed bounded: yes / no / not exercised
Notes / device console reference:

Physical-device A/B result: UNVERIFIED until this template is completed from the device.
Release/TestFlight result: UNVERIFIED.
```

This checkpoint does not claim the physical root cause is resolved. Do not
remove or broaden haptics based on simulator behavior; use the physical A/B
and Release/TestFlight evidence before selecting any further fix.
