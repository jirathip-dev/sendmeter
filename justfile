# Sendmeter — fleet-lane task runner (just)
# Install once: brew install just
# Every recipe mirrors what CI actually runs (see .github/workflows/).
# NOTE: web/Capacitor surface was retired in #857 — this repo is native-only.

# default: show recipes
default:
    @just --list

# --- fast, no simulator -------------------------------------------------

# Watch pure-logic package tests (runs on host, no simulator)
watch-core:
    swift test --package-path ios/App/SendLogWatchCore

# Health/readiness math tests (runs on host, no simulator)
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

# Slop scan + both Swift core test suites (the fast lane after edits)
fast: slop watch-core health-core

# --- xcodegen (required before any xcodebuild) --------------------------

# Regenerate Xcode projects from project.yml (XcodeGen)
gen:
    xcodegen generate

# --- build (needs Xcode; CODE_SIGNING_ALLOWED=NO like CI) ---------------

# Build the native iOS app (unsigned, generic destination)
build-ios:
    xcodebuild -project native/SendmeterNative/SendmeterNative.xcodeproj \
      -scheme SendmeterNative -configuration Debug \
      -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Build the watch app (unsigned, generic destination)
build-watch:
    xcodebuild -project native/SendmeterNative/SendmeterNative.xcodeproj \
      -scheme 'SendLogWatch Watch App' -configuration Debug \
      -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build

# --- full parity with native-swift.yml Core tests -----------------------

# Everything CI gates on, in CI order (excludes simulator-only steps)
ci: slop slop-cold watch-core health-core build-ios build-watch
