# Evidence — issue #991 (`impl-991`)

The app-group read that emitted
`Using kCFPreferencesAnyUser with a container is only allowed for System
Containers, detaching from cfprefsd` on every cold launch, and its fix:
`ReadinessWidgetStore` now reads/writes the App Group domain through an
explicit `kCFPreferencesCurrentUser` `CFPreferences` access
(`ReadinessWidgetAppGroupDefaults` in
`native-plugins/sendlog-health-core/Sources/SendLogHealthCore/ReadinessWidgetContract.swift`).
Full write-up: `.report-991.md` in the worktree root.

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
| `SHA256SUMS` | Digests of every file in this directory. |

Not included: the 3.6 MB raw probe `xcodebuild` log and the host disassembly
dumps (`/tmp/cfd-disasm.txt`, `/tmp/fdn-disasm.txt`, `/tmp/wc-disasm.txt`) —
regenerable by the commands quoted in `991-mechanism.txt`.
