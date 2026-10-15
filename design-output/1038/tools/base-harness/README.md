# Build-58 ("before") harness

The before screenshots are captured from `origin/staging` @ `2ee391e` (= build 58) with a
DEBUG-only harness on top, so before and after render the real app over the **same** seed data.

- `build58-harness.diff`: the edits to tracked files (AppModel / TindeqBluetooth DEBUG setters,
  SendmeterNativeApp / ForceView launch hooks).
- `DesignFixture1038Base.swift`: the new file (states + seed data, copied from the after harness).

States (`--design-1038 <state>`): `force-handsfree-armed`, `force-recording`, `force-guided-armed`,
`force-zone-armed`, `force-disconnected`, `force-picker`.

Reproduce:

    git worktree add --detach /tmp/sm-base 2ee391e
    cd /tmp/sm-base && git apply <this dir>/build58-harness.diff
    cp <this dir>/DesignFixture1038Base.swift native/SendmeterNative/Sources/App/
    cd native/SendmeterNative && xcodegen generate
    xcodebuild -project SendmeterNative.xcodeproj -scheme SendmeterNative -configuration Debug \
      -destination 'id=<udid>' -derivedDataPath /tmp/dd-base CODE_SIGNING_ALLOWED=NO build
    design-output/1038/tools/capture-phone.sh /tmp/dd-base/Build/Products/Debug-iphonesimulator/Sendmeter.app \
      <udid> design-output/1038/before/<device> before-<device> $(cat design-output/1038/tools/states-before.txt)
