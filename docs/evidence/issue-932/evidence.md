# #932 evidence — bounded native UI smoke suite (menu + manual-workout)

Lane `impl-932`, worktree `~/.herdr/worktrees/sendmeter/impl-932`, base
`b2c4df4282a5c617fb986cf7e2b72ec6b016fb68` (= `origin/staging` at dispatch).

The change is `.github/workflows/native-swift.yml` + `justfile` (plus this
evidence and `.report-1.md`). **Nothing under `Sources/**` changed**, so every
behaviour below is the production code at this head.

The **hosted run is NOT in this set** — this lane cannot open a PR and the
workflow's automatic triggers are `pull_request` and `push` to
`staging`/`main`. `.report-1.md` hands the orchestrator the exact step.

## What each artifact proves

| artifact | layer / command | observed result |
|---|---|---|
| `ui-smoke-green.log.gz` | lane worktree, cold build, `iphone17pro-sendmeter` (iPhone 17 Pro, iOS 26.5, 3×), `-derivedDataPath /tmp/impl932-dd`, `-resultBundlePath` | `Executed 4 tests, with 0 failures`, `** TEST SUCCEEDED **`, `RAW_EXIT=0` |
| `xcresult-summary-green.json` | `xcrun xcresulttool get test-results summary` on that run's bundle | `totalTestCount 4`, `passedTests 4`, `failedTests 0`; device `iphone17pro-sendmeter` / iOS 26.5 recorded |
| `count-assert-positive.log.gz` | the workflow's *“Assert the UI smoke suite executed its expected tests”* block, extracted from the YAML and run against the real bundle | exit 0, `UI smoke suite executed 4 tests (expected 4)` + the four test names |
| `count-assert-negative.log.gz` | the same block with `EXPECTED_UI_SMOKE_TESTS=999` | exit 1 + `::error::executed 4 tests; expected 999 — a selector that matches nothing runs zero tests and exits 0` (the gate bites) |
| `ui-smoke-red.log.gz`, `probe-refusal-routing.diff`, `xcresult-summary-red.json` | scratch copy `/tmp/impl932-redgreen` with the refusal-presentation action reverted to its pre-#926 shape | `Executed 4 tests, with 4 failures` (2 tests, 4 assertions), `** TEST FAILED **`, `RAW_EXIT=65`; summary `passedTests 2 / failedTests 2` |
| `ui-smoke-green-after-restore.log.gz` | the same copy after restoring the file (sha256 identical to the worktree file — see below) | `Executed 4 tests, with 0 failures`, `RAW_EXIT=0` |
| `apptarget-saveonce.log.gz` | focused app-target run `-only-testing:SendmeterNativeTests/ManualWorkoutSaveOnceAppTests` (the durable half of AC2) | `Executed 1 test, with 0 failures`, `RAW_EXIT=0` |
| `just-fast.log.gz` | `just fast` (slop + the three SwiftPM suites) at the lane head | `JUST_FAST_EXIT=0`; core **1344** / watch-core **600** / health-core **66**, 0 failures |
| `build-ios-attempt.log.gz` | bounded `just build-ios` (host DerivedData pinned to the unattached `/Volumes/NVMe2TB`) | `xcodebuild: error: Could not resolve package dependencies: You don’t have permission to save the file “repositories” in the folder “SourcePackages”`, exit **74** |
| `gitleaks-committed-tree.log.gz` | `gitleaks 8.30.1` over the committed-file surface (1 048 files), run **from the tree root** so the path-anchored allowlist matches, flags identical to `secret-scan.yml` | `no leaks found`, `EXIT=0` |
| `gitleaks-worktree-run2-with-spm-checkouts.log.gz` | repo-root worktree scan after `just fast` fetched SPM checkouts — a `--source .` + `--no-git` scan also covers gitignored directories | 11 findings, **all** inside `native/SendmeterNative/.build/checkouts/GRDB.swift/**` (vendored SQLite sources; build output that does not exist on a CI checkout). Disclosed, not committed, not a product finding |
| `anti-slop-linter.log.gz` | `bash scripts/anti-slop-swift.sh native/SendmeterNative/Sources` | exit 1: **1 pre-existing finding** (`Sources/Core/DirectWriteReplay.swift:198`, `no-force-unwrap`) in a file this lane does not touch (`git diff --stat b2c4df42 -- native/SendmeterNative/Sources` is empty). CI's step treats findings as advisory (exit 1 ⇒ warning), tool failure as blocking |
| `check-static.log.gz` | `just check-static` | exit 1: **pre-existing** (`scripts/validate-native-static.sh` requires `Sources/Features/Force/ManualForceFullscreen.swift`, absent at base and head); not wired into `just ci` |
| `gen.log.gz`, `check-watch-project.log.gz`, `slop.log.gz`, `docs-stale-check.log.gz`, `just-list.log.gz` | `just gen`, `just check-watch-project`, `just slop`, `scripts/check-docs-stale-commands.sh`, `just --list` | exit 0 each |

## AC4 splice (byte evidence)

Mutation (COPY only — the worktree file was never in a mutated state):

```
-    private func presentEndRefusal(_ message: String) {
-        guard showManualWorkout else {
-            model.errorMessage = message
-            return
-        }
-        endRefusal = ManualWorkoutEndRefusal(message: message)
+    private func presentEndRefusal(_ message: String) {
+        model.errorMessage = message
     }
```

RED failures are exactly the refusal-dependent journeys (`ui-smoke-red.log.gz`):

```
ManualWorkoutEndRefusalUITests.swift:32: error: … XCTAssertTrue failed - a refused End must explain itself inside the full-screen workout
ManualWorkoutEndRefusalUITests.swift:82: error: … XCTAssertTrue failed - fixture: the refusal must be on screen before minimizing
ManualWorkoutEndRefusalUITests.swift:101: error: … XCTAssertFalse failed - minimizing must not leave an obsolete error on the tab
```

The other two tests (`testCompletedAttemptEndsWithoutARefusal`,
`testMenuActivationPresentsAndTicksOnce`) stayed green in the same run —
the mutation discriminates the named journeys, it does not break the suite.

The app under test was proved to BE the mutated build (not a stale install):

```
$ xcrun simctl get_app_container <sim> com.jirathip.sendlog.native
…/Sendmeter.app
3f08b462fc7d009225b3f068494ae1f7adf60c2dd1443be5ce3b9883d1cc8cdb  <container>/Sendmeter.app/Sendmeter.debug.dylib
3f08b462fc7d009225b3f068494ae1f7adf60c2dd1443be5ce3b9883d1cc8cdb  /tmp/impl932-redgreen-dd/Build/Products/Debug-iphonesimulator/Sendmeter.app/Sendmeter.debug.dylib
```

Restore proof (before the GREEN re-run): the copy's `WorkoutView.swift` sha256
equals the worktree file —
`95ce34b95e61296c0cc3691143a2e370fe9246e085d4e07ccfe038364b150af5` on both —
and the GREEN re-run's installed dylib sha256 equals that build product
(`25e21a38fae70d6b31f2a42a67c3ef6f58be26f4ab17e06a7b0372d01bb2c620`).

## Exact commands (reproducible)

Green leg (worktree), the CI body with a lane-local derived-data path:

```
cd native/SendmeterNative
xcrun simctl bootstatus 0E127B96-BF94-48E0-A61B-0C018D9D79C7 -b
xcodebuild test \
  -project SendmeterNative.xcodeproj -scheme SendmeterNative -configuration Debug \
  -destination "id=0E127B96-BF94-48E0-A61B-0C018D9D79C7" \
  -only-testing:SendmeterNativeUITests/MenuActivationUITests \
  -only-testing:SendmeterNativeUITests/ManualWorkoutEndRefusalUITests \
  -resultBundlePath /tmp/impl932-uitests.xcresult \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/impl932-dd
```

Copy legs additionally run `xcrun simctl uninstall <sim> com.jirathip.sendlog.native`
first so the previous leg's build can never be reused.

Secret-scan emulation of the CI surface:

```
git ls-files -co --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C /tmp/impl932-committed-tree
cd /tmp/impl932-committed-tree
gitleaks detect --source . --no-git --config .gitleaks.toml --redact --verbose --no-color --no-banner --exit-code=1
```

Note for future lanes: scanning an export by ABSOLUTE path (`--source /tmp/…`)
false-positives on the two allowlisted fixture files, because
`.gitleaks.toml`'s allowlist anchors `^ios/App/…SupabaseService\.swift$` and
`^tools/anti-slop-swift/README\.md$` — `cd` into the tree first.

## What this set does NOT cover

- The hosted `native-swift.yml` run at the lane head (needs a PR or a
  `workflow_dispatch` — see `.report-1.md` for the exact command).
- `SendmeterNativeTests` as a whole at this head (only the focused save-once
  class above was run; the app-target step is unchanged by this lane).
- Physical-device haptics / HealthKit / BLE (separate gates, untouched).
