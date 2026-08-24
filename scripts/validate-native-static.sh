#!/usr/bin/env bash
set -euo pipefail

# This is the strongest native-source gate that does not invoke xcodebuild.
# SwiftPM intentionally compiles only SendmeterCore, while the application
# target also contains SwiftUI/UIKit/ActivityKit code that needs Xcode's SDK
# and package graph for a real typecheck. Parse every native source and test
# file here, then have XcodeGen prove that the app target still contains the
# Force files touched by the native parity work.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
native_root="$repo_root/native/SendmeterNative"

cd "$repo_root"

swift_files=()
while IFS= read -r path; do
    swift_files+=("$repo_root/$path")
done < <(rg --files native/SendmeterNative/Sources native/SendmeterNative/Tests -g '*.swift' | sort)

if ((${#swift_files[@]} == 0)); then
    echo "No native Swift files found" >&2
    exit 1
fi

echo "Parsing ${#swift_files[@]} native Swift source/test files"
for file in "${swift_files[@]}"; do
    # Parse one file at a time because the app and Core layers intentionally
    # contain a few same-named private helpers (for example Haptics.swift).
    swiftc -parse "$file"
done

generated_root=$(mktemp -d "${TMPDIR:-/tmp}/sendmeter-native-xcodegen.XXXXXX")
trap 'rm -rf "$generated_root"' EXIT

xcodegen generate \
    --quiet \
    --spec "$native_root/project.yml" \
    --project "$generated_root" \
    --project-root "$native_root"

project_file="$generated_root/SendmeterNative.xcodeproj/project.pbxproj"
if [[ ! -f "$project_file" ]]; then
    echo "XcodeGen did not produce $project_file" >&2
    exit 1
fi

for source in ForceView.swift ManualForceFullscreen.swift ForceTrendChart.swift NativeForceCurveCard.swift; do
    if ! rg -q "$source" "$project_file"; then
        echo "Generated project is missing the Force source: $source" >&2
        exit 1
    fi
done

force_view="$native_root/Sources/Features/Force/ForceView.swift"
if ! rg -q 'ForceContextLockPolicy\.isLocked' "$force_view" \
    || ! rg -q 'handsFreeArmed: model\.handsFree\.isArmed' "$force_view"; then
    echo "Force recording-context lock invariant is missing" >&2
    exit 1
fi

fullscreen="$native_root/Sources/Features/Force/ManualForceFullscreen.swift"
if ! rg -q 'recording keeps running in the Force tab until you stop or disconnect' "$fullscreen"; then
    echo "Manual fullscreen accessibility copy is stale" >&2
    exit 1
fi

echo "Native parse, generated-project wiring, and Force invariants passed"
