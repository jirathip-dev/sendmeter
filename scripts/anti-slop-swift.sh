#!/usr/bin/env bash
set -euo pipefail

# Reproducible native Swift source lint. The executable and its SwiftSyntax
# dependency are both resolved from the committed package under tools/.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool_root="$repo_root/tools/anti-slop-swift"
config="$repo_root/.anti-slop.json"

if [[ ! -f "$config" ]]; then
    echo "anti-slop: missing $config" >&2
    exit 1
fi

if (($# == 0)); then
    set -- "$repo_root/native/SendmeterNative/Sources"
fi

exec swift run \
    --package-path "$tool_root" \
    --configuration release \
    anti-slop \
    "--config=$config" \
    "$@"
