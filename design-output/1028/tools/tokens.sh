#!/usr/bin/env bash
# #1028 B3 — regenerate (or --check) design-output/1028/tokens.md from the
# shipped Foundation-only palette sources. Exit 1 on any AA failure, or
# with --check when the committed tokens.md is stale.
#
# Usage (repo root):
#   design-output/1028/tools/tokens.sh          # rewrite tokens.md
#   design-output/1028/tools/tokens.sh --check  # verify committed copy
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CORE="$ROOT/ios/App/SendLogWatchCore/Sources/SendLogWatchCore"
OUT="$ROOT/design-output/1028/tokens.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tokens1028.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -O -module-name Tokens1028 \
  "$CORE/SendmeterPalette.swift" "$CORE/WatchDesign.swift" "$CORE/WorkoutPhaseFill.swift" \
  "$(dirname "$0")/tokens/main.swift" -o "$WORK/tokens"

if [[ "${1:-}" == "--check" ]]; then
  "$WORK/tokens" "$WORK/tokens.md"
  diff -u "$OUT" "$WORK/tokens.md" && echo "tokens.md is current"
else
  "$WORK/tokens" "$OUT"
fi
