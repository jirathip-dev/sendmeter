#!/usr/bin/env bash
set -euo pipefail

# SwiftPM does not compile the SwiftUI application target. Keep this tiny
# iPhoneOS-SDK probe beside the source gates so the real explicit initializer
# and every app call site stay type-checked without invoking xcodebuild.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe_root=$(mktemp -d "${TMPDIR:-/tmp}/sendmeter-empty-state-sdk.XXXXXX")
trap 'rm -rf "$probe_root"' EXIT

progress_source="$repo_root/native/SendmeterNative/Sources/Features/Force/ForceProgressCard.swift"
consistency_source="$repo_root/native/SendmeterNative/Sources/Features/Force/ForceConsistencyCard.swift"
curve_source="$repo_root/native/SendmeterNative/Sources/Features/Force/NativeForceCurveCard.swift"
force_source="$repo_root/native/SendmeterNative/Sources/Features/Force/ForceView.swift"
detail_source="$repo_root/native/SendmeterNative/Sources/Features/Force/StaticCapacityDetailView.swift"

if rg -q 'ProductEmptyState\(|showsPrimaryEmptyState|emptyAction' \
    "$progress_source" "$consistency_source"; then
    echo "Secondary Force cards still contain a dead primary-empty-state seam" >&2
    exit 1
fi

if [[ "$(rg -c '^\s+NativeForceCurveCard\(' "$force_source" || true)" != "1" \
    || "$(rg -c '^\s+NativeForceCurveCard\(' "$detail_source" || true)" != "1" ]]; then
    echo "Expected exactly one NativeForceCurveCard call in each app owner" >&2
    exit 1
fi

# Extract the actual stored declarations and explicit initializer from the
# app source. This deliberately does not duplicate member lists in the probe:
# adding a stored property or initializer parameter changes the code that is
# type-checked below.
native_properties=$(awk '
    /^struct NativeForceCurveCard: View/ { inside = 1; next }
    inside && /^    @Environment/ { exit }
    inside && /^    let / { print }
' "$curve_source")

extract_braced_block() {
    local file=$1
    local marker=$2
    awk -v marker="$marker" '
        !found && index($0, marker) { found = 1 }
        found {
            print
            line = $0
            opens = gsub(/\{/, "", line)
            closes = gsub(/\}/, "", line)
            depth += opens - closes
            if (opens > 0) { started = 1 }
            if (started && depth == 0) { exit }
        }
    ' "$file"
}

extract_call() {
    local file=$1
    awk '
        !found && /NativeForceCurveCard\(/ { found = 1 }
        found {
            print
            line = $0
            opens = gsub(/\(/, "", line)
            closes = gsub(/\)/, "", line)
            depth += opens - closes
            if (depth == 0) { exit }
        }
    ' "$file"
}

native_init=$(extract_braced_block "$curve_source" "    init(")
force_call=$(extract_call "$force_source")
detail_call=$(extract_call "$detail_source")

if [[ -z "$native_properties" || -z "$native_init" \
    || -z "$force_call" || -z "$detail_call" ]]; then
    echo "Could not extract the real NativeForceCurveCard declaration/call sites" >&2
    exit 1
fi

probe="$probe_root/EmptyStateInitializers.swift"

{
    cat <<'SWIFT'
import SwiftUI

struct ForceCurveModel {}
struct ForceTargetBand {}

struct NativeForceCurveCard: View {
SWIFT
    printf '%s\n' "$native_properties"
    printf '%s\n' "$native_init"
    cat <<'SWIFT'
    var body: some View { EmptyView() }
}

struct ForceModelStub {
    let hasLoadedRecordings = false
}

struct ForceViewCallSite: View {
    let tag = ""
    let forceCurve: ForceCurveModel? = nil
    let forceModel = ForceModelStub()
    let selectedTargetReferenceBand: ForceTargetBand? = nil
    let forceConnectionPending = false
    let forceEmptyActionTitle = ""

    func performForceEmptyAction() {}

    var body: some View {
SWIFT
    printf '%s\n' "$force_call"
    cat <<'SWIFT'
    }
}

struct StaticCapacityDetailCallSite: View {
    let selectedTag = ""
    let forceCurve: ForceCurveModel? = nil
    let hasLoadedRecordings = false
    let targetBand: ForceTargetBand? = nil
    let connectionPending = false

    func dismiss() {}

    var body: some View {
SWIFT
    printf '%s\n' "$detail_call"
    cat <<'SWIFT'
    }
}
SWIFT
} > "$probe"

xcrun --sdk iphoneos swiftc \
    -typecheck \
    -target arm64-apple-ios17.0 \
    -swift-version 5 \
    -module-name SendmeterEmptyStateSDKProbe \
    "$probe"

echo "iPhoneOS SDK empty-state initializer probe passed"
