#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p png
PW_CORE="${PW_CORE:-$(ls -d "$HOME"/.npm/_npx/*/node_modules/playwright-core | head -1)}"
CHROME="${CHROME:-$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium-*/chrome-mac-arm64/*.app/Contents/MacOS/* | head -1)}"
PW_CORE="$PW_CORE" CHROME="$CHROME" node render.mjs ${@:-pick confirm error}
