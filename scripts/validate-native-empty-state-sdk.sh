#!/usr/bin/env bash
set -euo pipefail

# SwiftPM does not compile the SwiftUI application target. Keep this tiny
# iPhoneOS-SDK probe beside the source gates so a stored-let initializer
# regression cannot hide behind `swiftc -parse` or source substring tests.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe_root=$(mktemp -d "${TMPDIR:-/tmp}/sendmeter-empty-state-sdk.XXXXXX")
trap 'rm -rf "$probe_root"' EXIT

probe="$probe_root/EmptyStateInitializers.swift"
progress_flag=$(awk '
    /^struct ForceProgressCard: View/ { inside = 1 }
    inside && /let showsPrimaryEmptyState: Bool/ { print; exit }
' "$repo_root/native/SendmeterNative/Sources/Features/Force/ForceProgressCard.swift")
consistency_flag=$(awk '
    /^struct ForceConsistencyCard: View/ { inside = 1 }
    inside && /let showsPrimaryEmptyState: Bool/ { print; exit }
' "$repo_root/native/SendmeterNative/Sources/Features/Force/ForceConsistencyCard.swift")
progress_source="$repo_root/native/SendmeterNative/Sources/Features/Force/ForceProgressCard.swift"
force_source="$repo_root/native/SendmeterNative/Sources/Features/Force/ForceView.swift"
secondary_owner_count=$(rg -c 'showsPrimaryEmptyState: false' "$force_source" || true)
has_progress_call=false
if rg -q 'showsPrimaryEmptyState: showsPrimaryEmptyState' "$progress_source"; then
    has_progress_call=true
fi

if [[ "$progress_flag" != *"let showsPrimaryEmptyState: Bool"* \
    || "$progress_flag" == *"="* \
    || "$consistency_flag" != *"let showsPrimaryEmptyState: Bool"* \
    || "$consistency_flag" == *"="* \
    || "$secondary_owner_count" != "3" \
    || "$has_progress_call" != true ]]; then
    echo "Force empty-state flags are not configurable stored properties" >&2
    exit 1
fi

{
cat <<'SWIFT'
import SwiftUI

struct TindeqRecording {}
struct ForceCurveModel {}
struct ForceTargetBand {}

// These declarations intentionally mirror the app-target stored properties.
// In particular, showsPrimaryEmptyState must have no stored default: the
// boundary and ForceView call sites below pass it explicitly.
struct ForceProgressCard: View {
    let recordings: [TindeqRecording]
    let selectedTag: String?
    let selectedSide: String?
    let forceCurve: ForceCurveModel?
    let hasLoadedRecordings: Bool
    let targetBand: ForceTargetBand?
SWIFT
printf '%s\n' "$progress_flag"
cat <<'SWIFT'
    let emptyActionTitle: String
    let emptyAction: () -> Void
    let connectionPending: Bool

    var body: some View { EmptyView() }
}

struct ForceProgressCardBoundary: View {
    let recordings: [TindeqRecording]
    let selectedTag: String?
    let selectedSide: String?
    let forceCurve: ForceCurveModel?
    let hasLoadedRecordings: Bool
    let targetBand: ForceTargetBand?
    let showsPrimaryEmptyState: Bool
    let emptyActionTitle: String
    let emptyAction: () -> Void
    let connectionPending: Bool

    var body: some View {
        ForceProgressCard(
            recordings: recordings,
            selectedTag: selectedTag,
            selectedSide: selectedSide,
            forceCurve: forceCurve,
            hasLoadedRecordings: hasLoadedRecordings,
            targetBand: targetBand,
            showsPrimaryEmptyState: showsPrimaryEmptyState,
            emptyActionTitle: emptyActionTitle,
            emptyAction: emptyAction,
            connectionPending: connectionPending
        )
    }
}

struct ForceConsistencyCard: View {
    let recordings: [TindeqRecording]
    let hiddenTags: Set<String>
    let hasLoadedRecordings: Bool
    let connectionPending: Bool
SWIFT
printf '%s\n' "$consistency_flag"
cat <<'SWIFT'
    let emptyActionTitle: String
    let emptyAction: () -> Void

    var body: some View { EmptyView() }
}

struct ForceViewCallSite: View {
    let recordings: [TindeqRecording]
    let hiddenTags: Set<String>
    let hasLoadedRecordings: Bool
    let connectionPending: Bool
    let emptyActionTitle: String
    let emptyAction: () -> Void

    var body: some View {
        ForceConsistencyCard(
            recordings: recordings,
            hiddenTags: hiddenTags,
            hasLoadedRecordings: hasLoadedRecordings,
            connectionPending: connectionPending,
            showsPrimaryEmptyState: false,
            emptyActionTitle: emptyActionTitle,
            emptyAction: emptyAction
        )
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
