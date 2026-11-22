#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
shell=${CHROME:-$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell | tail -1)}
mkdir -p png
for d in ${DIRS:-chalk zine graffiti}; do
  for s in ${SCREENS:-today route}; do
    case $s in route) tall=1160 ;; *) tall=900 ;; esac
    for size in 390x$tall 1440x900; do
      w=${size%x*}
      "$shell" --headless --disable-gpu --hide-scrollbars --allow-file-access-from-files \
        --force-device-scale-factor=1 --virtual-time-budget=3000 --window-size="${size/x/,}" \
        --screenshot="png/$d-$s-$w.png" "file://$PWD/$s.html?d=$d" 2>/dev/null
    done
  done
done
ls png
