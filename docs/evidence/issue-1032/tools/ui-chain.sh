#!/usr/bin/env bash
# #1032: the SE clearance GREEN run, then the four UI RED probes, serially
# (one xcodebuild at a time). Usage (repo root): bash .../ui-chain.sh <log-dir> <tag>
set -uo pipefail
L="$1"; TAG="$2"
T="$(cd "$(dirname "$0")" && pwd)"
bash "$T/clearance-se.sh" "$L/clearance-se-$TAG.log"; echo "clearance-se-$TAG exit=$?" | tee "$L/clearance-se-$TAG.exit"
for p in ui-dashboard ui-workout ui-history ui-settings; do
  bash "$T/red-probes.sh" "$p" "$L" | tee -a "$L/red-probes-ui.txt"
done
