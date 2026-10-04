# Evidence — issue #991 (`impl-991`)

The app-group read that emitted
`Using kCFPreferencesAnyUser with a container is only allowed for System
Containers, detaching from cfprefsd` on every cold launch, and its fix:
`ReadinessWidgetStore` now reads/writes the App Group domain through an
explicit `kCFPreferencesCurrentUser` `CFPreferences` access
(`ReadinessWidgetAppGroupDefaults` in
`native-plugins/sendlog-health-core/Sources/SendLogHealthCore/ReadinessWidgetContract.swift`).
Fix rounds 1–2: the CF accessor is compiled only on Apple targets
(`#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)`).
Round 1's `canImport(CoreFoundation)` module-availability guard was wrong —
Linux ships a CoreFoundation *subset* without CFString/CFPreferences, and the
ios-ci `package-tests` container compiled the block; corrected in round 2 —
see `fix2-guard-truth-table.txt`. Every other platform selects the
Foundation-only `ReadinessWidgetFallbackDefaults` — same domain, key and
nil-on-unreadable semantics.
Full write-ups: `.report-991.md` (round 0), `.report-991-fix1.md` (round 1)
and `.report-991-fix2.md` (round 2, current) in the worktree root.

| file | what it is |
|---|---|
| `991-device-log-ordering.txt` | Raw transcript lines (build-55 device capture) — launch 1 + launch 2 windows, all 4 refused-source lines, and the re-derived ordering: the app's own container lookup → sandbox extension → refused AnyUser source on the callback thread, after the signed-in relay only. |
| `991-mechanism.txt` | The mechanism: Apple CF source (`_CFApplicationPreferencesAddSuitePreferences` adds AnyUser suite domains), the refusal string in the iOS 26.5 simulator CoreFoundation, the modern search-list block that wires suite sources, the Foundation suite-init body, and the WatchConnectivity-binary negative proof (`nm -u` / full disassembly: zero CFPreferences/UserDefaults/container references). |
| `991-sim-probe.txt` | Pre-fix simulator probe output (temporary test, deleted): the CurrentUser CFPreferences read/write and the suite path share one storage on the simulator; `containerURL(forSecurityApplicationGroupIdentifier:)` is nil on the simulator (the containerized-preference refusal is device-only). |
| `red-wiring-pin.log.gz` | RED proof: `swift test --package-path native/SendmeterNative --filter PhonePrivacyManifestsMatchTheAppGroupCallPath` against the **base** contract — exit 1, the new pins fail at the suite-API/missing-CF assertions (gzipped). |
| `green-wiring-pin.log.gz` | GREEN: same filter against the fixed contract — exit 0, test passed (gzipped). |
| `health-core-final-run1.log.gz` …`-run3.log.gz` | `just health-core` (×3) after the fix: 67 tests, 0 failures each (gzipped). |
| `health-core-json-keyorder-repro1.log.gz` / `-repro2.log.gz` | Reproductions of the first-draft regression test failing on JSON key-order (byte-compare) before it was fixed to compare decoded values — kept for disclosure. |
| `core-suite.log.gz` | `just core` — 1510 tests, 0 failures (gzipped). |
| `anti-slop.log.gz` | `just slop` — exit 0 (gzipped; the repo's `.gitignore` hides `*.log`, so gate logs ship gzipped). |
| `app-target-suite-01.log.gz` | The app-target CI-shape `xcodebuild test … -only-testing:SendmeterNativeTests -derivedDataPath …` run (flock-serialized). Contains the raw command line and the raw exit at the end (`APP_SUITE_EXIT=65`; the red is the pre-existing #941 test — see `app-target-base-red-ci.txt`; gzipped). |
| `app-target-base-red-ci.txt` | The same app-target job failing on hosted CI for the exact lane base (run 37197803088, the #1009 merge) — raw failing-test lines; base-identity for the red. |
| `app-target-suite-02.log.gz` | Full app-target suite re-run on the lane's own freshly created simulator (`impl991-pro17`), because the shared simulator was concurrently exercised by the review-989 lane re-running the same flaky classes. `APP_SUITE_RERUN_EXIT=0` — 172 tests, 0 failures (the app-target gate result of record; gzipped). |
| `fix1-linux-static-guarantee.txt` | Fix round 1: the Linux `package-tests` failure and the platform-split static guarantee — the only CF-bearing code sits behind `#if canImport(CoreFoundation)`, the `#else` branch and the fallback file are CF-symbol-free, module imports are Foundation-only, and what could not be run here (no Linux toolchain/SDK, no Docker daemon). |
| `fix1-wiring-pin-red.log.gz` | Fix round 1 RED: the current pin (with the two platform-split assertions) against the complete pre-fix source state (base contract + fallback file absent, clean rebuild) — exit 1, five assertion failures at lines 114/115/117/122/123 (gzipped). |
| `fix1-wiring-pin-green.log.gz` | Fix round 1 GREEN: same filter against the split contract — exit 0, test passed (gzipped). |
| `fix1-health-core.log.gz` | `just health-core` after the split: 69 tests (67 + the 2 new fallback tests), 0 failures (gzipped). |
| `fix1-health-core-fallback-filter.log.gz` | Focused run of the two new `ReadinessWidgetFallbackDefaults` tests — both passed (gzipped). |
| `fix1-core.log.gz` | `just core` after the split — 1510 tests, 0 failures, including the extended wiring pin (gzipped). |
| `fix1-slop.log.gz` | `just slop` — exit 0 (gzipped). |
| `fix1-docs-check.log.gz` | `just docs-check` — exit 0 (gzipped). |
| `fix1-watch-core.log.gz` | The failing CI job's own command run on macOS (`swift test --package-path ios/App/SendLogWatchCore`) — exit 0, 600 tests, 0 failures (gzipped). |
| `fix2-guard-truth-table.txt` | Fix round 2: the guard's truth table (per-target branch and why), the probe/SIL commands actually run, the per-platform selection summary, and the Linux-side static guarantee. |
| `fix2-sil-selection-{macosx,iphoneos,iphonesimulator,watchos,watchsimulator}.txt` | The compiled `appGroupStore.getter` SIL body per Apple SDK — each allocates `ReadinessWidgetAppGroupDefaults` (the CoreFoundation accessor), zero errors. |
| `fix2-ci-run1-package-tests.log.gz` | The raw `package-tests` job log at head `2acdf482` (job 111439538188): the Linux container compiled the round-1 `canImport(CoreFoundation)` block — 80 `cannot find` errors at ReadinessWidgetContract.swift:182-209. The raw evidence that supersedes `fix1-linux-static-guarantee.txt`'s Linux claim. |
| `fix2-wiring-pin-red.log.gz` | Fix round 2 RED: the pin (os() guard + no-canImport assertions) against the pre-fix source state — exit 1, five assertion failures at lines 114/115/117/125/129 (gzipped). |
| `fix2-wiring-pin-green.log.gz` | Fix round 2 GREEN: same filter on the fix head — exit 0, test passed (gzipped). |
| `fix2-health-core.log.gz` | `just health-core` on the fix head: 70 tests (incl. the new `testAppGroupStoreSelectsThePlatformAccessor`), 0 failures (gzipped). |
| `fix2-core.log.gz` | `just core` on the fix head — 1510 tests, 0 failures, extended pin included (gzipped). |
| `fix2-watch-core.log.gz` | The `package-tests` job's command run on macOS on the fix head (`swift test --package-path ios/App/SendLogWatchCore`) — exit 0, 600 tests (gzipped). |
| `fix2-slop.log.gz` / `fix2-docs-check.log.gz` | `just slop` / `just docs-check` on the fix head — exit 0 (gzipped). |
| `fix2-ci-run2-package-tests.log.gz` | The raw `package-tests` job log at the source head `310f1aa` (job 111442146702, completed success). The containing run was later marked run-level `cancelled` by concurrency when the next push arrived — the job had already completed; this log was captured before the cancellation. |
| `fix2-ci-run3-package-tests.log.gz` | The raw `package-tests` job log at the tip `c12f44b` (job 111442718465, completed success) — same sources, re-verified on Linux. |
| `SHA256SUMS` | Digests of every file in this directory. |

Not included: the 3.6 MB raw probe `xcodebuild` log and the host disassembly
dumps (`/tmp/cfd-disasm.txt`, `/tmp/fdn-disasm.txt`, `/tmp/wc-disasm.txt`) —
regenerable by the commands quoted in `991-mechanism.txt`.
