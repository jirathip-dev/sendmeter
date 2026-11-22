#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$root/scripts/xcodegen.sh"
cd "$root/native/SendmeterNative"
strict=(CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES)
project=(-project SendmeterNative.xcodeproj -scheme SendmeterNative -configuration Debug)
xcodebuild "${project[@]}" -resolvePackageDependencies
xcodebuild "${project[@]}" -destination 'generic/platform=iOS Simulator' "${strict[@]}" build
udid=$(bash "$root/scripts/simulator.sh" iOS)
xcodebuild test "${project[@]}" -destination "id=$udid" -only-testing:SendmeterNativeTests "${strict[@]}"
bundle="$root/target/ui-smoke/ui-smoke.xcresult"
rm -rf "${bundle:?}"
mkdir -p "$(dirname "$bundle")"
xcodebuild test "${project[@]}" -destination "id=$udid" \
  -only-testing:SendmeterNativeUITests/MenuActivationUITests \
  -only-testing:SendmeterNativeUITests/ManualWorkoutEndRefusalUITests \
  -resultBundlePath "$bundle" "${strict[@]}"
executed=$(xcrun xcresulttool get test-results summary --path "$bundle" --compact | jq -r '.totalTestCount')
if [[ "$executed" != 4 ]]; then
  echo "UI smoke suite executed $executed tests, expected 4: a selector that matches nothing runs zero tests and exits 0" >&2
  exit 1
fi
