#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool_root="$repo_root/tools/anti-slop-swift"
source_root="$repo_root/native/SendmeterNative/Sources"

if [[ ! -f "$tool_root/Package.swift" || ! -f "$tool_root/Package.resolved" ]]; then
    echo "anti-slop cold-build: missing vendored tool package" >&2
    exit 2
fi

if ! tool_bin=$(swift build \
    --package-path "$tool_root" \
    --configuration debug \
    --show-bin-path
); then
    echo "anti-slop cold-build: could not determine debug bin path" >&2
    exit 2
fi
tool_executable="$tool_bin/anti-slop"

if ! swift package clean --package-path "$tool_root"; then
    echo "anti-slop cold-build: could not clean the debug product" >&2
    exit 2
fi

if [[ -x "$tool_executable" ]]; then
    echo "anti-slop cold-build: debug executable survived package clean" >&2
    exit 2
fi

if ! output_file=$(mktemp "${TMPDIR:-/tmp}/anti-slop-cold.XXXXXX"); then
    echo "anti-slop cold-build: could not create a temporary output file" >&2
    exit 2
fi
trap 'rm -f "$output_file"' EXIT

set +e
bash "$repo_root/scripts/anti-slop-swift.sh" "$source_root" >"$output_file" 2>&1
lint_status=$?
set -e

cat "$output_file"

case "$lint_status" in
    0)
        ;;
    1)
        echo "anti-slop cold-build: findings are advisory after a successful build"
        ;;
    *)
        echo "anti-slop cold-build: wrapper failed on a clean debug product (exit $lint_status)" >&2
        exit 2
        ;;
esac

if ! grep -F -q -- "anti-slop: scanned " "$output_file"; then
    echo "anti-slop cold-build: missing positive scan signal" >&2
    exit 2
fi

if [[ ! -x "$tool_executable" ]]; then
    echo "anti-slop cold-build: wrapper did not produce the debug executable" >&2
    exit 2
fi

echo "anti-slop cold-build: absent debug product was built and scanned successfully"
