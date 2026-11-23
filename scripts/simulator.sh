#!/usr/bin/env bash
set -euo pipefail
platform=$1
devices=$(xcrun simctl list devices available --json)
if [[ "$platform" == watchOS ]]; then
  udid=$(jq -r '[.devices[][] | select(.name == "gatekeeper-watch")] | first | .udid' <<<"$devices")
  if [[ -z "$udid" || "$udid" == null ]]; then
    type=$(jq -r '[.devices | to_entries[] | select(.key | contains("watchOS")) | .value[]] | first | .deviceTypeIdentifier' <<<"$devices")
    runtime=$(xcrun simctl list runtimes --json |
      jq -r '[.runtimes[] | select(.platform == "watchOS" and .isAvailable)] | last | .identifier')
    if [[ "$type" != null && "$runtime" != null ]]; then
      udid=$(xcrun simctl create gatekeeper-watch "$type" "$runtime")
    fi
  fi
else
  udid=$(jq -r --arg p "$platform" '[.devices | to_entries[] | select(.key | contains($p)) | .value[]] | first | .udid' <<<"$devices")
fi
if [[ -z "$udid" || "$udid" == null ]]; then
  echo "no available $platform simulator" >&2
  xcrun simctl list devices >&2
  exit 1
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >&2
echo "$udid"
