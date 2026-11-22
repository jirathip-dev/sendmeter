#!/usr/bin/env bash
set -euo pipefail
platform=$1
udid=$(xcrun simctl list devices available --json |
  jq -r --arg p "$platform" '[.devices | to_entries[] | select(.key | contains($p)) | .value[]] | first | .udid')
if [[ -z "$udid" || "$udid" == null ]]; then
  echo "no available $platform simulator" >&2
  xcrun simctl list devices >&2
  exit 1
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >&2
echo "$udid"
