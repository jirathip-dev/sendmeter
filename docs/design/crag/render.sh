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
  shot today-rain-390 390,844 "s=today&m=rain"
  shot today-rain-1440 1440,900 "s=today&m=rain"
  shot today-dawn-390 390,844 "s=today&m=dawn"
  shot today-fog-1440 1440,900 "s=today&m=fog"
  shot session-rain-390 390,844 "s=session&m=rain"
  shot buttons-390 390,600 "s=buttons"
  shot buttons-1440 1440,420 "s=buttons"
  shot states-390 390,880 "s=states"
  shot states-1440 1440,800 "s=states"
  shot icons-390 390,1460 "s=icons"
  shot icons-1440 1440,640 "s=icons"
  shot mascots-390 390,940 "s=mascots"
  shot mascots-1440 1440,600 "s=mascots"
  shot model-390 390,900 "s=model"
  shot model-1440 1440,520 "s=model"
  shot watch-390 390,640 "s=watch"
  shot watch-1440 1440,400 "s=watch"
fi
ls png | wc -l
