# Evidence — issue 923 (native/sync: publish successful refresh slices when an unrelated entity fetch fails)

Lane `impl-920` (worktree `~/.herdr/worktrees/sendmeter/impl-920`), base
`origin/staging` = `02e3d8968ace81b46eeb9b014e239d193bafcd54`.

All logs here are raw runs from this host, gzipped byte-exact (`.log` is
gitignored in this repo).

| file | command | raw outcome |
|---|---|---|
| `app-target-full.log.gz` | `xcodebuild test -project native/SendmeterNative/SendmeterNative.xcodeproj -scheme SendmeterNative -destination "id=C604626D-CABE-4525-AA4F-3B9F4FE1A7E8" -only-testing:SendmeterNativeTests CODE_SIGNING_ALLOWED=NO -derivedDataPath /Users/jirathip/impl920-derived` | exit **0**, `** TEST SUCCEEDED **`, `Executed 135 tests, with 0 failures` — no `-skip-testing`, on `impl920-sim` freshly erased (`simctl shutdown/erase/boot`) |
| `app-target-focused.log.gz` | the same command with `-only-testing:SendmeterNativeTests/SyncSurfacesAppTests -only-testing:SendmeterNativeTests/SyncSurfacesRenderEvidenceTests` | exit **0**, `Executed 13 tests, with 0 failures`, 7 `EVIDENCE_FRAME #n …` lines (the frames in `docs/evidence/issue-920/`) |
| `just-fast.log.gz` | `just fast` | exit **0**: anti-slop passed; `SendmeterNative` **1392** tests / 0 failures; `SendLogWatchCore` **600** / 0; `sendlog-health-core` **66** / 0 |
| `probe-C.log.gz` + `probe-C.diff` | probe C (RED): every publish gate requires `outcomes.didFullyRefresh`, i.e. the pre-#923 rule where any failure discards every sibling slice | `xcodebuild test … -only-testing:SendmeterNativeTests/SyncSurfacesAppTests/testFailingSliceKeepsLastGoodDataWhileSiblingsPublish` in the mutated tree | exit **65** with the test failing: `("1") is not equal to ("2") - the sessions slice published its new row` and `XCTAssertNotEqual failed … the successfully reconciled slice advanced its own cursor`. The file was restored from its snapshot afterwards and its sha256 matches the original (`95bf95da…`, printed by the probe runner) |

## Symptom → mechanism map for the change

| symptom before this diff | mechanism now | file:line |
|---|---|---|
| one entity's fetch failure cancelled the reconciliation of every sibling (`async let` + `try await` in sequence) | per-slice `SliceFetch` outcomes, folded into `RefreshSliceOutcomes` | `Sources/App/AppModel.swift:2642`–`:2760`, `Sources/Core/RefreshSlicePlan.swift:93` |
| a partially authoritative group could be published | publish gates per `RefreshConsistencyGroup` (`sessionsAndRecordings`, `settingsAndPhase` are the two dependent pairs) | `AppModel.swift:2915`–`:3010`, `Sources/Core/RefreshSlicePlan.swift:12`–`:120` |
| the account-wide freshness stamp advanced even when slices failed | stamped only under `outcomes.didFullyRefresh` | `AppModel.swift:3071` |
| a partial failure could escalate to the total-offline banner | `shouldSurface(source:hasLastGoodData:publishedAnySlice:)` suppresses it once any group published; the scoped `RefreshFailureSummary` carries the retry instead | `Sources/Core/ErrorSurfacePolicy.swift:48`, `AppModel.swift:2694`, `Features/Settings/SettingsView.swift` |
