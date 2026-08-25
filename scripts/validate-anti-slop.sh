#!/usr/bin/env bash
set -euo pipefail

# Structural checks for the advisory native lint integration. The linter
# itself is run separately so this check stays fast and can fail if the
# config/CI contract drifts even when no Swift compiler is available.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
config="$repo_root/.anti-slop.json"
workflow="$repo_root/.github/workflows/native-swift.yml"
wrapper="$repo_root/scripts/anti-slop-swift.sh"
tool_root="$repo_root/tools/anti-slop-swift"
source_root="$repo_root/native/SendmeterNative/Sources"

[[ -f "$config" ]] || { echo "Missing $config" >&2; exit 1; }
[[ -f "$workflow" ]] || { echo "Missing $workflow" >&2; exit 1; }
[[ -x "$wrapper" ]] || { echo "Missing executable $wrapper" >&2; exit 1; }
[[ -f "$tool_root/Package.swift" ]] || { echo "Missing vendored Package.swift" >&2; exit 1; }
[[ -f "$tool_root/Package.resolved" ]] || { echo "Missing vendored Package.resolved" >&2; exit 1; }
[[ -f "$tool_root/LICENSE" ]] || { echo "Missing vendored MIT license" >&2; exit 1; }
[[ -d "$source_root" ]] || { echo "Missing native Swift source root" >&2; exit 1; }

python3 - "$config" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

expected = {"disabled": ["no-any-dictionary-value", "no-any-parameters"]}
if config != expected:
    raise SystemExit(
        f".anti-slop.json must equal {expected!r}; got {config!r}"
    )
PY

swift_file_count=$(find "$source_root" -type f -name '*.swift' -print | wc -l | tr -d '[:space:]')
if [[ "$swift_file_count" -eq 0 ]]; then
    echo "Native CI source root contains no Swift files" >&2
    exit 1
fi

required_wrapper_fragments=(
    '--show-bin-path'
    'anti-slop: scanned'
    'lint_status=$?'
    'exit 2'
)
for fragment in "${required_wrapper_fragments[@]}"; do
    if ! grep -F -q -- "$fragment" "$wrapper"; then
        echo "Anti-slop wrapper is missing required failure/scanned-file handling: $fragment" >&2
        exit 1
    fi
done

step_file=$(mktemp "${TMPDIR:-/tmp}/anti-slop-step.XXXXXX")
trap 'rm -f "$step_file"' EXIT
awk '
    $0 == "      - name: Anti-slop Swift (advisory)" { in_step = 1 }
    in_step && /^      - name: / && $0 != "      - name: Anti-slop Swift (advisory)" { exit }
    in_step { print }
' "$workflow" > "$step_file"

[[ -s "$step_file" ]] || { echo "Missing named anti-slop CI step" >&2; exit 1; }

required_step_fragments=(
    'name: Anti-slop Swift (advisory)'
    'bash scripts/anti-slop-swift.sh native/SendmeterNative/Sources'
    'case "$lint_status" in'
    '1)'
    'exit 0'
    '::warning'
    '::error'
)
for fragment in "${required_step_fragments[@]}"; do
    if ! grep -F -q -- "$fragment" "$step_file"; then
        echo "Native CI anti-slop step is missing required advisory/failure handling: $fragment" >&2
        exit 1
    fi
done

if grep -F -q -- 'continue-on-error: true' "$step_file"; then
    echo "Native CI anti-slop step must fail tool errors instead of blanket continue-on-error" >&2
    exit 1
fi

echo "Anti-slop config, wrapper, source path, and advisory CI wiring passed"
