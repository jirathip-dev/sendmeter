# Sendmeter — fleet-lane task runner (just)
# Install once: brew install just
# Every recipe mirrors what CI actually runs (see .github/workflows/).
# NOTE: web/Capacitor surface was retired in #857 — this repo is native-only.

# default: show recipes
default:
    @just --list

# --- fast, no simulator -------------------------------------------------

# PRIMARY gate: full native SwiftPM suite (~1136 tests, host, no simulator)
core:
    swift test --package-path native/SendmeterNative

# Watch pure-logic package tests (host, no simulator)
watch-core:
    swift test --package-path ios/App/SendLogWatchCore

# Health/readiness math tests (host, no simulator)
health-core:
    swift test --package-path native-plugins/sendlog-health-core

# Anti-slop gate (same as native-swift.yml "Core tests")
slop:
    bash scripts/validate-anti-slop.sh

# Anti-slop cold-check variant
slop-cold:
    bash scripts/validate-anti-slop-cold.sh

# Static validation of the native empty-state SDK
check-static:
    bash scripts/validate-native-static.sh

# --- docs surface (text-only, no compiler; CI: native-swift.yml) ---------

# The stale-command check's historical allowlist is explicit — a (path, reason)
# pair per file — and lives in scripts/check-docs-stale-commands.sh. Running it
# from here or from CI never relaxes it: a new entry is a script change that
# states its reason, not a suppression at the call site.

# Stale-command check for the current contributor entrypoints (same as the "Docs stale-command check" job in native-swift.yml)
docs-check:
    bash scripts/check-docs-stale-commands.sh

# Slop scan + all three Swift test suites (the fast lane after edits)
fast: slop core watch-core health-core

# --- xcodegen (required before any xcodebuild) --------------------------

# Regenerate Xcode projects from project.yml (XcodeGen)
gen:
    cd native/SendmeterNative && xcodegen generate

# Generated-project ownership gate (run after any gen-affecting change)
check-watch-project:
    ruby scripts/assert-native-watch-project.rb

# --- build (needs Xcode; CODE_SIGNING_ALLOWED=NO like CI) ---------------

# Build the native iOS app (unsigned, generic destination)
build-ios:
    cd native/SendmeterNative && xcodebuild \
      -project SendmeterNative.xcodeproj \
      -scheme SendmeterNative -configuration Debug \
      -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Build the watch app (unsigned, generic destination)
build-watch:
    cd native/SendmeterNative && xcodebuild \
      -project SendmeterNative.xcodeproj \
      -scheme 'SendLogWatch Watch App' -configuration Debug \
      -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build

# --- Watch app-target tests (simulator-only; mirrors native-swift.yml) ----

# Watch app-target tests (SendLogWatchTests, needs a watchOS simulator; CI: native-swift.yml)
watch-app-tests:
    cd native/SendmeterNative && UDID=$(xcrun simctl list devices available --json | jq -r '[.devices | to_entries[] | select(.key | contains("watchOS")) | .value[]] | first | .udid') && xcrun simctl bootstatus "$UDID" -b && xcodebuild test -project SendmeterNative.xcodeproj -scheme 'SendLogWatch Watch App' -configuration Debug -destination "id=$UDID" -only-testing:SendLogWatchTests CODE_SIGNING_ALLOWED=NO

# --- UI smoke suite (simulator-only; mirrors native-swift.yml) -----------

# Bounded native UI smoke suite: menu activation + manual-workout End/refusal/minimize (CI: native-swift.yml)
ui-tests:
    cd native/SendmeterNative && UDID=$(xcrun simctl list devices available --json | jq -r '[.devices | to_entries[] | select(.key | contains("iOS")) | .value[]] | first | .udid') && xcrun simctl bootstatus "$UDID" -b && xcodebuild test -project SendmeterNative.xcodeproj -scheme SendmeterNative -configuration Debug -destination "id=$UDID" -only-testing:SendmeterNativeUITests/MenuActivationUITests -only-testing:SendmeterNativeUITests/ManualWorkoutEndRefusalUITests CODE_SIGNING_ALLOWED=NO

# --- full parity with native-swift.yml Core tests -----------------------

# Everything CI gates on, in CI order (excludes simulator-only steps)
ci: docs-check slop slop-cold core watch-core health-core gen check-watch-project build-ios build-watch
