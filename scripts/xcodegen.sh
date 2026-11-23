#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=2.46.0
sum=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
dir="$root/target/xcodegen/$version"
bin="$dir/xcodegen/bin/xcodegen"
if [[ ! -x "$bin" ]]; then
  mkdir -p "$dir"
  curl --fail --location --silent --show-error --output "$dir/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
  echo "$sum  $dir/xcodegen.zip" | shasum --algorithm 256 --check --strict
  unzip -q -o "$dir/xcodegen.zip" -d "$dir"
fi
cd "$root/native/SendmeterNative"
"$bin" generate --quiet
ruby "$root/scripts/assert-native-watch-project.rb"
