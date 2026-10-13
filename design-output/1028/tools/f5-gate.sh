#!/usr/bin/env bash
# #1028 F5: run TabBarClearanceUITests on the SE simulator (GREEN), then
# prove it bites: move the Force bar from the bottom safe-area inset to a
# plain overlay (content then scrolls under it) and expect a Force failure
# (RED). The mutated file is restored byte-for-byte by a trap.
# While the RED run is in flight the source tree IS mutated: do not run
# `swift test` (or any build) on this worktree concurrently. A unit-test run
# that overlapped it failed ForceMotionWiringTests' safeAreaInset pin. The
# gate holds $LOCK so other tools can wait for it.
set -uo pipefail
LOCK=/Users/jirathip/.hermes/profiles/designer/cache/scratch/d1028/f5-gate.mutating
S=/Users/jirathip/.hermes/profiles/designer/cache/scratch/d1028
W=/Users/jirathip/.herdr/worktrees/sendmeter/design-1028-refine/native/SendmeterNative
SE=1B8EA94B-502E-4FF4-8E99-3296819BEF07
F=Sources/Features/Force/ForceView.swift
cd "$W"
run() { # $1 = log name
  while pgrep -x xcodebuild >/dev/null; do sleep 5; done
  rm -rf "$S/$1.xcresult"
  xcodebuild test -project SendmeterNative.xcodeproj -scheme SendmeterNative \
    -destination "id=$SE" -derivedDataPath "$S/dd-uitest" \
    -only-testing:SendmeterNativeUITests/TabBarClearanceUITests \
    -resultBundlePath "$S/$1.xcresult" CODE_SIGNING_ALLOWED=NO > "$S/logs/$1.log" 2>&1
  echo "EXIT=$?" >> "$S/logs/$1.log"
}
run f5-green
cp "$F" "$S/ForceView.swift.keep"
SUM=$(shasum "$F" | cut -d' ' -f1)
touch "$LOCK"
trap 'cp "$S/ForceView.swift.keep" "$W/$F"; rm -f "$LOCK"; echo "restored $(shasum "$W/$F" | cut -d" " -f1) (expected $SUM)" >> "$S/logs/f5-red.log"' EXIT
LINE=$(grep -n '^            \.safeAreaInset(edge: \.bottom, spacing: 0) {$' "$F" | head -1 | cut -d: -f1)
[[ -n "$LINE" ]] || { echo "mutation anchor not found" > "$S/logs/f5-red.log"; exit 2; }
sed -i '' "${LINE}s/\.safeAreaInset(edge: \.bottom, spacing: 0) {/.overlay(alignment: .bottom) {/" "$F"
echo "mutated line $LINE: $(sed -n "${LINE}p" "$F")" > "$S/logs/f5-red.mutation"
run f5-red
