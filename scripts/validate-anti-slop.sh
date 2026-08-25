#!/usr/bin/env bash
set -euo pipefail

# Structural checks for the advisory native lint integration. The linter
# itself is run separately so this check stays fast and can fail if the
# config/CI contract drifts even when no Swift compiler is available.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
config="$repo_root/.anti-slop.json"
workflow="$repo_root/.github/workflows/native-swift.yml"

[[ -f "$config" ]] || { echo "Missing $config" >&2; exit 1; }
[[ -f "$workflow" ]] || { echo "Missing $workflow" >&2; exit 1; }

python3 - "$config" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

expected = ["no-any-dictionary-value", "no-any-parameters"]
if config.get("disabled") != expected:
    raise SystemExit(
        f".anti-slop.json must disable exactly {expected!r}; "
        f"got {config.get('disabled')!r}"
    )
PY

required_fragments=(
    'name: Anti-slop Swift (advisory)'
    'continue-on-error: true'
    'scripts/anti-slop-swift.sh native/SendmeterNative/Sources'
    '::warning'
)
for fragment in "${required_fragments[@]}"; do
    if ! rg -Fq "$fragment" "$workflow"; then
        echo "Native CI is missing anti-slop advisory wiring: $fragment" >&2
        exit 1
    fi
done

echo "Anti-slop config and advisory CI wiring passed"
