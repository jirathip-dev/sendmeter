#!/usr/bin/env bash
set -euo pipefail

# Reproducible native Swift source lint. The executable and its SwiftSyntax
# dependency are both resolved from the committed package under tools/. A
# debug build keeps the advisory CI pass cheap; the AST rules are identical
# to the release executable.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool_root="$repo_root/tools/anti-slop-swift"
config="$repo_root/.anti-slop.json"

if [[ ! -f "$config" || ! -f "$tool_root/Package.swift" || ! -f "$tool_root/Package.resolved" ]]; then
    echo "anti-slop: missing config or vendored tool package" >&2
    exit 2
fi

if (($# == 0)); then
    set -- "$repo_root/native/SendmeterNative/Sources"
fi

swift_file_count=0
for path in "$@"; do
    if [[ ! -e "$path" ]]; then
        echo "anti-slop: no such scan path: $path" >&2
        exit 2
    fi
    if [[ -d "$path" ]]; then
        while IFS= read -r -d '' file; do
            swift_file_count=$((swift_file_count + 1))
        done < <(
            find "$path" \
                \( -type d \( -name .git -o -name .build -o -name .swiftpm -o -name DerivedData \) -prune \) \
                -o \( -type f -name '*.swift' -print0 \)
        )
    elif [[ "$path" == *.swift ]]; then
        swift_file_count=$((swift_file_count + 1))
    fi
done

if ((swift_file_count == 0)); then
    echo "anti-slop: scan contains zero Swift files" >&2
    exit 2
fi

if ! swift build \
    --package-path "$tool_root" \
    --configuration debug \
    --product anti-slop
then
    echo "anti-slop: vendored tool build failed" >&2
    exit 2
fi

if ! tool_bin=$(swift build \
    --package-path "$tool_root" \
    --configuration debug \
    --product anti-slop \
    --show-bin-path
); then
    echo "anti-slop: could not determine vendored tool bin path" >&2
    exit 2
fi

tool_executable="$tool_bin/anti-slop"
if [[ ! -x "$tool_executable" ]]; then
    echo "anti-slop: built executable is missing: $tool_executable" >&2
    exit 2
fi

set +e
"$tool_executable" \
    "--config=$config" \
    "$@"
lint_status=$?
set -e

case "$lint_status" in
    0|1)
        echo "anti-slop: scanned $swift_file_count Swift files"
        exit "$lint_status"
        ;;
    *)
        echo "anti-slop: tool failed before a clean scan completed (exit $lint_status)" >&2
        exit 2
        ;;
esac
