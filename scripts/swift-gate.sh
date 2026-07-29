#!/bin/sh
# Swift correctness gate for agent-ops dispatch (issue #319).
#
# agent-ops only runs the npm gates (test/lint/typecheck — .agent/config.yaml)
# on every dispatched issue, so a watch/iOS-only change could reach CI having
# never compiled a line of Swift (#315/#277). agent-ops' `Commands` model has
# no custom gate names, so this is chained onto `test` there rather than
# added as its own gate.
#
# Skips entirely (exit 0) when nothing under ios/ differs from the base
# branch, so web-only runs — the majority — pay ~nothing.
#
# Coverage: SendLogWatchCore's SPM tests plus an xcodebuild of the
# "SendLogWatch Watch App" scheme (which also builds SendLogWatchWidgets, the
# target #315/#277 slipped through). NOT covered: the phone App target
# (ios/App/App/*.swift, e.g. AppDelegate.swift, LiveActivityIntents.swift) —
# its Xcode target embeds ios/App/App/public as a Resources build-phase
# folder reference, which only exists after `npm run build && cap sync`; a
# fresh worktree without that step fails the Resources copy regardless of
# Swift correctness, so building it here would false-fail every iOS run
# rather than close the gap (tracked separately, filed off the back of
# #319). Also not covered: native-plugins/ (this gate only watches ios/,
# matching #319's acceptance criteria), so a native-plugins-only change is
# not covered either.
set -eu

cd "$(dirname "$0")/.."

BASE="${SWIFT_GATE_BASE:-}"
if [ -z "$BASE" ]; then
  for candidate in origin/staging staging origin/main main; do
    if git rev-parse "$candidate" >/dev/null 2>&1; then
      BASE="$candidate"
      break
    fi
  done
fi

if [ -z "$BASE" ]; then
  echo "swift-gate: could not resolve a base branch (tried \$SWIFT_GATE_BASE, origin/staging, staging, origin/main, main) — cannot tell whether ios/ changed. Failing loud rather than silently skipping." >&2
  exit 1
fi

MERGE_BASE=$(git merge-base HEAD "$BASE")

TRACKED_CHANGES=$(git diff --name-only "$MERGE_BASE" -- ios/)
UNTRACKED_CHANGES=$(git ls-files --others --exclude-standard -- ios/)

if [ -z "$TRACKED_CHANGES" ] && [ -z "$UNTRACKED_CHANGES" ]; then
  exit 0
fi

if ! command -v swift >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "swift-gate: ios/ changed but this runner cannot compile Swift (swift/xcodebuild missing or non-functional). Failing loud so the run escalates to needs-human instead of silently passing — see #319, #307." >&2
  exit 1
fi

echo "swift-gate: ios/ changed — running SendLogWatchCore tests + watch scheme build"

(cd ios/App/SendLogWatchCore && swift test)

xcodebuild build \
  -project "ios/App/App.xcodeproj" \
  -scheme "SendLogWatch Watch App" \
  -destination "generic/platform=watchOS Simulator" \
  -derivedDataPath "$PWD/DerivedData" \
  CODE_SIGNING_ALLOWED=NO
