# Native touch-latency A/B checkpoint (#816)

Status: diagnostic checkpoint only. The root structural-haptics hypothesis is
not proven, and no physical-device result is recorded here. The native app's
default behavior is unchanged unless a DEBUG launch argument is supplied.

## Diagnostic variants

All variants use the same DEBUG source revision and data:

| Variant | Launch value | Root default-button gesture | Explicit `HapticTapModifier` paths | Direct action haptics / behavior |
| --- | --- | --- | --- | --- |
| Default | no argument | current behavior | current behavior | unchanged; no diagnostic banner |
| A | `A` | ON | ON | unchanged; banner says `A` |
| B | `B` | OFF; SwiftUI stock button behavior | ON | unchanged; banner says `B` |
| B′ | `b-prime` | ON | OFF | unchanged; banner says `B′` |

B′ is included because this source revision has both the root
`StructuralDefaultButtonStyle` and explicit `.hapticTap` / `.hapticButtonStyle`
call sites. It isolates the explicit attachment path without muting direct
`Haptics.shared.play(...)` / `playGesture(...)` action cues. Use it only if B
does not separate the behavior.

The parser is compiled into the app's DEBUG path only. Release/TestFlight
always resolves to the unlabelled default and cannot be enabled by a launch
argument. A, B, and B′ show a red, non-interactive in-app banner so the
variant is unambiguous on the phone. The banner uses
`.allowsHitTesting(false)`; ErrorBanner and AppToast retain bounded content
shapes for their own controls.

## Copy-paste physical-device procedure

Run this on a Mac with a signed-in development team and a connected physical
iPhone. Use a throwaway/test account because this DEBUG device build uses the
native app's hosted Supabase configuration.

```bash
cd /Users/jirathip/.herdr/worktrees/sendmeter/orch-816-touch-latency
xcrun devicectl list devices
export DEVICE_UDID="<physical-iPhone-UDID>"
export NATIVE_DERIVED_DATA="$(mktemp -d /tmp/sendmeter-native-816.XXXXXX)"

cd native/SendmeterNative
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

The Debug bundle identifier is `com.jirathip.sendlog.native`. Launch the same
installed app three times as A, then three times as B, using the argument after
the bundle identifier:

```bash
xcrun devicectl device process launch \
  --device "$DEVICE_UDID" \
  --terminate-existing \
  com.jirathip.sendlog.native \
  -sendmeter-structural-haptics A

xcrun devicectl device process launch \
  --device "$DEVICE_UDID" \
  --terminate-existing \
  com.jirathip.sendlog.native \
  -sendmeter-structural-haptics B
```

For B′ after an inconclusive B, relaunch the same installed binary with:

```bash
xcrun devicectl device process launch \
  --device "$DEVICE_UDID" \
  --terminate-existing \
  com.jirathip.sendlog.native \
  -sendmeter-structural-haptics b-prime
```

Alternatively, put `-sendmeter-structural-haptics` and `A` (or `B` / `b-prime`)
as two separate entries in Xcode's **Scheme → Run → Arguments Passed on
Launch**. Confirm the red banner before recording each trial. Keep A and B on
the same installed build and data state; do not update or reinstall between
variants unless the install itself is broken.

## Three-trial matrix

Perform three comparable trials for every row in A and B. Record B′ only when
B is inconclusive. Start each trial from the same visible screen and include a
fresh cold launch where noted. Count every physical haptic you can perceive;
do not infer a haptic from source code or simulator behavior.

| Surface / state | Actions to exercise | Trial observations |
| --- | --- | --- |
| Dashboard | Scroll from blank space, a row, and a card; tap cards/buttons; open and dismiss charts and sheets; exercise NavigationLinks | first-motion latency; missed/duplicate actions; haptic count |
| Workout | Scroll blank space and rows/cards; tap buttons and NavigationLinks; open/close routine/workout sheets; repeat a first-motion gesture | first-motion latency; missed/duplicate actions; haptic count |
| History | Scroll from blank space, rows, and cards; scrub HR/effort/force charts; multi-select; open sheets; use NavigationLinks and buttons | first-motion latency; missed/duplicate actions; haptic count |
| Settings | Scroll blank space and rows; tap cards/buttons; open/dismiss sheets and alerts; use NavigationLinks; include ErrorBanner/AppToast when available | first-motion latency; missed/duplicate actions; haptic count; confirm overlay taps stay inside visible bounds |
| Force, no live Progressor | Scroll blank space and cards; open charts/sheets; tap controls, rows, and NavigationLinks; trigger refused/disabled paths | first-motion latency; missed/duplicate actions; haptic count |
| Force, live Progressor | Connect a real Progressor; repeat blank-space/card/button/row starts while the live surface updates; scrub charts; open sheets and NavigationLinks | first-motion latency; missed/duplicate actions; haptic count; note connection/stream state |

For each surface, include at least one scroll that starts on blank content, one
that starts on a row/card, and one control/button tap. For charts, record both a
scrub and a transition into/out of the chart. For sheets and NavigationLinks,
record both presentation and dismissal/back navigation. Do not treat a
simulator run or a missing Progressor as a physical live-Progressor result.

## Evidence template

```text
Issue: #816
Source revision / commit:
Device model:
iOS version:
Native DEBUG app build / bundle ID:
Progressor firmware/model (or “not connected”):
Tester / date / local time:

Variant: A / B / B′
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

Physical-device result: UNVERIFIED until this template is completed from the device.
```

This checkpoint claims no final haptic fix. Do not remove or rewrite the
structural haptics based on simulator behavior; Guy must supply the A/B/device
result before any root-cause fix is selected.
