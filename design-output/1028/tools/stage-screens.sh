#!/usr/bin/env bash
# #1028 — stage raw simulator captures into design-output/1028/screens/.
#
# Phone captures are 3x (1185 px wide on a 17 Pro); the repo keeps a 50%
# copy (1.5x, sharp on a phone, ~4x smaller). Full-resolution originals go
# to the private design-output archive. Metadata chunks are stripped so a
# re-run on the same input is byte-identical.
#
# Usage (repo root): stage-screens.sh <capture-root>
#   <capture-root>/{before,after}/{17pro,se,watch}/*.png
set -euo pipefail
SRC="$1"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="$ROOT/design-output/1028/screens"
# Fail closed before touching the repo: every phone capture must show the
# app (not the splash or the home screen). Watch faces are flat by nature.
shopt -s nullglob
PHONE=("$SRC"/{before,after}/{17pro,se}/*.png)
python3 "$(dirname "$0")/check-shots.py" "${PHONE[@]}" || { echo "stage aborted: recapture the rejects" >&2; exit 1; }
for VERSION in before after; do
  for DEVICE in 17pro se watch; do
    IN="$SRC/$VERSION/$DEVICE"
    [[ -d "$IN" ]] || continue
    OUT="$DEST/$VERSION/$DEVICE"
    rm -rf "$OUT"; mkdir -p "$OUT"
    for FILE in "$IN"/"$VERSION"-*.png; do
      [[ "$(basename "$FILE")" == *sheet* ]] && continue
      SCALE=50%; [[ "$DEVICE" == watch ]] && SCALE=100%
      magick "$FILE" -resize "$SCALE" -strip \
        -define png:exclude-chunks=date,time -define png:compression-level=9 \
        "$OUT/$(basename "$FILE")"
    done
    echo "$VERSION/$DEVICE: $(ls "$OUT" | wc -l | tr -d ' ') files"
  done
done
