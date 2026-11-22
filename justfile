# Sendmeter: every gate runs through gatekeeper, the same locally and in CI (.github/workflows/gates.yml)

default:
    @just --list

# Every gate: the same command CI and drover's done check run
check:
    ./.gatekeeper/run check

# Regenerate SendmeterNative.xcodeproj from project.yml with the pinned XcodeGen (before opening Xcode)
gen:
    bash scripts/xcodegen.sh
