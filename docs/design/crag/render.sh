#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
shell=${CHROME:-$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell | tail -1)}
mkdir -p png
shot() {
  "$shell" --headless --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=1 --virtual-time-budget=3000 --window-size="$2" \
    --screenshot="png/$1.png" "file://$PWD/index.html?$3" 2>/dev/null
}
other() { case $1 in topo) echo log;; chalk) echo session;; journal) echo force;; headlamp) echo route;; esac; }
for t in ${THEMES:-topo chalk journal headlamp}; do
  for s in today "$(other "$t")"; do
    shot "$t-$s-390" 390,844 "t=$t&s=$s"
    shot "$t-$s-1440" 1440,900 "t=$t&s=$s"
  done
done
shot scenes-390 390,1180 "s=scenes"
shot scenes-1440 1440,640 "s=scenes"
shot icons-390 390,760 "s=icons"
shot icons-1440 1440,560 "s=icons"
ls png
