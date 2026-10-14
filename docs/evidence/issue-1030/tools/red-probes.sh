#!/usr/bin/env bash
# #1030 RED probes (NOT committed edits): each probe plants one defect, runs the
# focused suite to a named log, records the raw exit, then restores the file
# byte-for-byte and proves the restore with sha256.
#
# Usage (repo root): docs/evidence/issue-1030/tools/red-probes.sh
#   logs -> docs/evidence/issue-1030/logs/red-*.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT"
LOGS=docs/evidence/issue-1030/logs
PKG=native/SendmeterNative

probe() { # <name> <file> <python-replace-old> <python-replace-new> <filter>
  local name="$1" file="$2" old="$3" new="$4" filter="$5"
  local before after
  before=$(shasum -a 256 "$file" | cut -d' ' -f1)
  cp "$file" "$file.redprobe"
  OLD="$old" NEW="$new" python3 - "$file" <<'PY'
import os, sys
p = sys.argv[1]
t = open(p).read()
old, new = os.environ["OLD"], os.environ["NEW"]
assert t.count(old) == 1, f"probe anchor not unique in {p}"
open(p, "w").write(t.replace(old, new))
PY
  swift test --package-path "$PKG" --filter "$filter" > "$LOGS/red-$name.log" 2>&1
  echo "red-$name exit=$?"
  mv "$file.redprobe" "$file"
  after=$(shasum -a 256 "$file" | cut -d' ' -f1)
  [[ "$before" == "$after" ]] && echo "red-$name restored sha256=$after" || { echo "red-$name RESTORE FAILED"; exit 3; }
}

# 1. Palette gate: a raw colour literal in a VIEW file must fail the gate.
probe palette-gate \
  native/SendmeterNative/Sources/Features/Workout/WorkoutView.swift \
  'let nextText = next.stage.kind == .rest ? SendmeterStyle.onCaution : SendmeterStyle.onPrimary' \
  'let nextText = next.stage.kind == .rest ? Color(hex: "#1A1A1A") : SendmeterStyle.onPrimary' \
  'SendmeterPaletteGateTests/testNoColorLiteralOutsideTokenFiles'

# 2. Contrast: dropping the pill label mix toward the raw hue (0.45 -> 0.85)
#    must take a pill below 4.5:1 and fail the AA test.
probe pill-contrast \
  ios/App/SendLogWatchCore/Sources/SendLogWatchCore/SendmeterPalette.swift \
  'public static let pillTextHueWeight = 0.45' \
  'public static let pillTextHueWeight = 0.85' \
  'SendmeterPaletteContrastTests/testEveryTextPairMeetsAAInBothThemes'
