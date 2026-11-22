#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$root/scripts/xcodegen.sh"
cd "$root/native/SendmeterNative"
xcodebuild -project SendmeterNative.xcodeproj -scheme SendmeterNative -resolvePackageDependencies
udid=$(bash "$root/scripts/simulator.sh" watchOS)
xcodebuild test -project SendmeterNative.xcodeproj -scheme 'SendLogWatch Watch App' -configuration Debug \
  -destination "id=$udid" -only-testing:SendLogWatchTests \
  CODE_SIGNING_ALLOWED=NO
