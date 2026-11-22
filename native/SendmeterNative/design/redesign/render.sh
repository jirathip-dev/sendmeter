#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$here" -c debug
"$here/.build/debug/redesign-render" "$here" "$@"
