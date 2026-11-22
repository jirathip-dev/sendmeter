#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
shell=${CHROME:-$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell | tail -1)}
shot() {
  "$shell" --headless --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=1 --virtual-time-budget=4000 --window-size="$2" \
    --screenshot="png/$1.png" "file://$PWD/index.html?$3" 2>/dev/null
}
SCREENS=${SCREENS:-"today conditions session board route send force log logbook settings appicon loading pick check cantread boardsetup wiring boardimport dataimport sync empty error firstrun"}
if [ -z "${KEEP:-}" ]; then rm -rf png; fi
mkdir -p png
for s in $SCREENS; do
  shot "$s-390" 390,844 "s=$s"
  shot "$s-1440" 1440,900 "s=$s"
done
if [ -z "${KEEP:-}" ]; then
  shot today-day-390 390,844 "s=today&m=day"
  shot today-day-1440 1440,900 "s=today&m=day"
  shot today-rain-390 390,844 "s=today&m=rain"
  shot today-golden-1440 1440,900 "s=today&m=golden"
  shot board-golden-1440 1440,900 "s=board&m=golden"
  shot states-390 390,1700 "s=states"
  shot states-1440 1440,640 "s=states"
  shot mascots-390 390,980 "s=mascots"
  shot mascots-1440 1440,640 "s=mascots"
  shot watch-390 390,900 "s=watch"
  shot watch-1440 1440,460 "s=watch"
fi
ls png | wc -l
