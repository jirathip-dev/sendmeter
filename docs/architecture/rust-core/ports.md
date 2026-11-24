# The port list: what the cleanup (#1066) keeps

Both users start over and there is no import (owner, 2026-11-24), so the old app is not kept running while the
new one is built. #1066 deletes it in one PR once this ADR is approved. This file is the list #1066 keeps.

**The rule.** Under `native/`, `ios/`, `native-plugins/`, `supabase/` and `mcp/`, a file not named here is
deleted by #1066. Every kept file has an end:

- **Port**: the named slice rewrites it in Rust and deletes the Swift file and its tests in the same PR.
- **Carry**: it stays Swift. The named slice moves or rewires it for the new app.

Three more rules for #1066:

- A kept file's tests stay with it (`Tests/SendmeterCoreTests/<Name>*Tests.swift`, the watch-core and
  health-core suites). They are where the port's test vectors come from.
- The three Swift packages still build and pass after the cleanup, so a port is proven by a run: its vectors
  are read by the Swift suite before the Swift is deleted. `swift/warnings` and `local/coverage` stay on, with
  the floors measured again. Where a listed file does not compile without a deleted one, #1066 cuts the part
  that needs it, or keeps the other file and names it in its PR body.
- The app and watch targets do not build between #1066 and the slices that bring them back (R2 the phone, L1
  the widgets, X2 the watch). Their gates (`local/app`, `local/watch`) leave with #1066 and return with those
  slices.

Counted by `wc -l` over this list on staging `d99394f2`: about 43,000 of today's 100,332 lines under the cap
stay (14,900 to port, 28,200 to carry).

## Port: `native/SendmeterNative/Sources/Core/` (60 of 111 files)

| Files | Becomes | Ends with |
|---|---|---|
| `DateSupport`, `AppUnits`, `MassFormatting` | `sm-domain` | R1 |
| `Models` | the row types, `sm-domain` and `sm-store` | A1 |
| `TagCatalog` | `sm-store` | A2 |
| `TindeqSessionMerge`, `HistorySelection` | the merge transaction, `sm-store` | A3 |
| `Metrics`, `TrainingLoad`, `AcwrProjection`, `AcwrStatusCard`, `ZoneMix`, `PhaseManager`, `TrainingBlockGuidance` | `sm-stats` | D1 |
| `RecoveryInputs`, `HealthMetricReconciliation`, `DashboardVerdict`, `SendConditions`, `SendConditionsDetails` | `sm-stats` | D2 |
| `ForceEngine`, `ForceCurveEngine`, `HandsFreeForceController`, `TindeqConsistency`, `ForceProgress`, `GaugeSessionRPE`, `ForceProtocolSelection`, `ExerciseSideMode` | `sm-force`; the curve fit in `sm-stats` | D3 |
| `WorkoutStats`, `HistoryDerivedData`, `HistoryFilters`, `HistoryTimeline`, `BoxPlot`, `WorkoutRawTrace` | `sm-stats` | D4 |
| `HealthBackgroundSync`, `HealthRefreshPolicy`, `ReadinessSyncPolicy` | when Health is read and readiness recomputed, `sm-app` | L1 |
| `ForceBarPolicy`, `ForceRecordingContextPolicy`, `ForceAutoReconnect`, `ForceDisconnectSalvage`, `ForceLaunchRecovery`, `ForceLockRecovery`, `ForceMotionPolicy`, `ForceSaveOutcome`, `GaugeSessionTracker`, `GaugeSessionSaveGate`, `GuidedActivityContent`, `GuidedActivityMirror`, `GuidedForceFullscreenPresentation` | the live force session, `sm-app` and `LiveFrame` | L2 |
| `WorkoutEngine`, `RoutineGate`, `RoutineUndo`, `RoutineAudio`, `RoutineRunnerPresentation`, `ManualWorkoutRest`, `ManualWorkoutLifecycleCoordinator`, `ManualWorkoutActivityContent`, `LiveWorkoutMirror`, `WatchCompletion`, `WatchMetadata` | the live session and the routine runner, `sm-app` | L3 |

Also ported, from `supabase/`: the six files of `supabase/tests/` and the seven migrations that define the
former RPCs (`20260712000000_delete_account`, `20260807090000_link_tindeq_recordings_rpc`,
`20260811090000_tindeq_tag_side_mode`, `20260814090000_phone_workout_rpc`,
`20260825090000_purge_sync_generation`, `20260828090000_health_metrics_precedence_rpc`,
`20260918090000_merge_tindeq_sessions_rpc`). They are A3's cases; A3 deletes them. The schema itself is in
`local-first/shapes.md`, so no other migration is kept.

## Carry: stays Swift

| Files | For | Reworked by |
|---|---|---|
| `Sources/Core/`: `Haptics`, `KeepAwake`, `SplashDynoTimeline`, `SplashPresentationFloor`, `ForceCurvePlotGeometry` | the live views' helpers and the splash | N2, L2 |
| `Sources/App/`: `SendmeterNativeApp` (for `SplashView`; N2 rewrites the rest), `Haptics`, `GuidedProtocolActivityManager`, `ManualWorkoutActivityManager`, `ManualWorkoutRestScheduler`, `ManualWorkoutRestAlert`, `LiveActivityIntents`, `ReadinessWidgetBridge`, `BackgroundSyncService` (the background-task wiring only) | the app's entry, Live Activities, rest alerts, the widget payload | N2, L1, L2, L3 |
| `Sources/Platform/`: all four (`HealthKitService`, `TindeqBluetooth`, `WatchConnectivityService`, `WeatherService`) with `Tests/SendmeterWeatherTests` | Apple Health, the Tindeq radio, the watch link, weather | L1, L2, X2, U1 |
| `Sources/Shared/`, `Sources/Widgets/`, `Resources/` | ActivityKit types, the widgets, assets, plists, the privacy manifest | L1, L2, L3 |
| `ios/App/SendLogWatchCore/` except `BackendFailureReason`, `UploadErrorPolicy`, `SessionRelay`, `QueueRetrySchedule`, `TagFetchPolicy`, `Quarantine*`, `WatchHealthReconcile`, `SyncFreshness` and their tests | the watch's pure logic: the attempt detector, the RPE model, the Tindeq format, the force and guided-force code, readiness on the watch | X1, X2, X3 |
| `ios/App/SendLogWatch Watch App/` except `SupabaseService`, `AuthManager`, `WatchSessionStore`, `Repo`, `HealthRepository`, `LiveWorkoutSync`, `LiveWorkoutTerminalRetry`, `UploadQueueEngine`, `OfflineQueue`, `OfflineQueueSeams`, `PendingRecordingQueue`, `PendingSessionQueue`, `QuarantineTrimNotice`, `QuarantineDiagnosticsView`, `SupabaseConfig.plist` | the watch app: workout, motion, Tindeq, Health and guided-force managers; today's views until X4 redraws them | X2, X3, X4 |
| `ios/App/SendLogWatchTests/`: the tests of kept files | the watch suite | X2 |
| `ios/App/SendLogWatchWidgets/`, the three `ios/App/*-Info.plist` | complications and Smart Stack | X2 |
| `native-plugins/sendlog-health-core/` | readiness on the watch, the widget contract | L1 |
| `native/SendmeterNative/design/redesign/` | #1046's approved screens: the expected value of each screen test, until #1060's replace them | N1, U1 to U7 |
| The build skeleton: `project.yml`, `Package.swift`, `Package.resolved`, `SendmeterNative.entitlements`, `fastlane/`, `Gemfile`, `Gemfile.lock`, `.mise.toml`, `native-testflight.yml`, and of `scripts/`: `xcodegen.sh`, `assert-native-watch-project.rb`, `simulator.sh`, `app-gate.sh`, `watch-gate.sh`, the three coverage scripts, `check-docs-stale-commands.sh` | building, testing and shipping the new app under the same bundle ids | R2, X2 |

The exceptions in the two watch rows are the Supabase-era files #1045 already listed as deleted
(`local-first/boundaries.md`).

## What the amendment named

| Named | Where it is on this list |
|---|---|
| The force curve fit | `ForceCurveEngine`: port, D3, into `sm-stats`, where #1065's personal force model will sit |
| The attempt detector | `SendLogWatchCore/AttemptDetector`: carry. It runs on the watch from live motion, and the watch links no Rust (`adr.md`, decision 7). If the owner picks option (b) of open question 1, it is ported into a pure crate the watch links |
| The Tindeq code | The byte format and the force engine: port, D3. The radio (`TindeqBluetooth`): carry, rewired to the `ble` contract in L2 |
| The board Bluetooth code | None exists yet: #1047 landed documents only. `sm-boards` and `BoardBluetooth` are written new (B1 to B8) from `docs/architecture/boards/` |

## Not kept, on purpose

- `AppModel.swift`, all of `Sources/Features/`, `Sources/Data/`, `DesignSystem.swift`, `ChartTheme.swift`: the
  screens are rebuilt in Rust from the approved designs, and the live views are redrawn on `LiveFrame`.
- The cache, the offline queue, the sync and auth machinery of `Sources/Core` (the "Deleted" list of
  `local-first/boundaries.md`), and the helpers of screens that no longer exist.
- `Tests/SendmeterNativeTests` and `Tests/SendmeterNativeUITests`: they test the old app's wiring.
- `mcp/`: #1066 deletes it. A server that reads the export folder can return as its own issue.
- Everything else in `supabase/`, its scripts and its two workflows.

A deleted file stays in git history until the history cut, and in the archive the cut keeps.
