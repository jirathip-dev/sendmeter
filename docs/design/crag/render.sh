#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
shell=${CHROME:-$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell | tail -1)}
mkdir -p png
shot() {
  "$shell" --headless --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=1 --virtual-time-budget=3000 --window-size="$2" \
    --screenshot="png/$1.png" "file://$PWD/$3" 2>/dev/null
}
for d in ${DIRS:-golden blue faded}; do
  shot "$d-today-390" 390,1300 "today.html?d=$d"
  shot "$d-today-1440" 1440,900 "today.html?d=$d"
  shot "$d-route-390" 390,1240 "route.html?d=$d"
  shot "$d-route-1440" 1440,900 "route.html?d=$d"
  shot "$d-loading-390" 390,844 "loading.html?d=$d"
  shot "$d-loading-1440" 1440,900 "loading.html?d=$d"
done
shot icons-390 390,900 "icon.html?d=golden"
shot icons-1440 1440,900 "icon.html?d=golden"
ls png
