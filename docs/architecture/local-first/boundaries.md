# Module boundaries after Supabase is gone

An arrow reads "may import". Nothing imports upward.

```
SendLogHealthCore        SendLogWatchCore            Blocks (types)        BlocksUI
   (pure)                (pure, Linux CI)             pinned tag           pinned tag
      ▲                    ▲          ▲                   ▲                    ▲
      │                    │          │                   │                    │
      └──── SendmeterCore ─┘          │                   │                    │
            (pure + GRDB)             │                   │                    │
                 ▲   ▲                │                   │                    │
                 │   └──── SendmeterScreens ──────────────┘                    │
                 │         (pure: Core + Blocks types)                         │
                 │               ▲                                             │
   ┌─────────────┴───────────────┴─────────────────────────────────────────────┴──┐
   │ App target                                                                   │
   │   Data/      CloudKit/ (CKSyncEngine), LegacyImport/ (URLSession), Export/   │
   │   Platform/  HealthKit, Bluetooth, WatchConnectivity, weather                │
   │   Features/  ScreenHost, Kinds/, live SwiftUI (recording, gauge, runner)     │
   │   App/       lifecycle, AppModel, Models/, Look                              │
   └──────────────────────────────────────────────────────────────────────────────┘

Watch app ──▶ SendLogWatchCore, SendLogHealthCore            (no GRDB, CloudKit, Blocks, Supabase)
mcp/      ──▶ the export folder                               (no network, no Swift)
```

| Module | Owns | May import | Must not import |
|---|---|---|---|
| `SendmeterCore` `Core/Store` | `LocalStore`, the SQL migrations, reads and write commands, the 8 former RPCs | GRDB, Foundation | CloudKit, SwiftUI, Blocks |
| `SendmeterCore` `Core/Sync` | `SyncState`, `reduce`, the conflict rules, row ↔ field mapping, the `CloudTransport` protocol | `Core/Store` | CloudKit, GRDB |
| `SendmeterCore` `Core/Export`, `Core/LegacyImport` | The export bundle from store rows; the row mapping and family state of the import | `Core/Store` | URLSession, CloudKit |
| `SendmeterCore` (the rest) | Models, metrics, force and workout engines: unchanged | `SendLogWatchCore`, `SendLogHealthCore` | GRDB |
| `SendmeterScreens` | One file per screen: read model → `Block` | `SendmeterCore`, `Blocks` | SwiftUI, BlocksUI, GRDB |
| `Data/CloudKit` | `CloudKitTransport`: engine events → `SyncEvent`, effects → engine calls | CloudKit, `SendmeterCore` | GRDB, SwiftUI |
| `Data/LegacyImport` | The PostgREST reader and the three sign-ins. Deleted when the window closes | Foundation, AuthenticationServices | any Supabase package |
| `Data/Export` | Writes the folder; picks iCloud Drive or Documents | Foundation | CloudKit |
| `Platform` | HealthKit, Bluetooth, `WatchLink`, weather | `SendmeterCore`, `SendLogWatchCore` | GRDB, CloudKit, BlocksUI |
| `Features` | `ScreenHost`, app kinds, live views, action handlers | BlocksUI, `SendmeterScreens`, `SendmeterCore` | GRDB, CloudKit |
| `App` | Lifecycle, `AppModel`, per-feature models, the `Look` | everything above | GRDB, CloudKit |
| `SendLogWatchCore` | Watch logic, `WatchSnapshot`, `WatchRecord`, `WatchRecordAck` | Foundation, `SendLogHealthCore` | everything else |
| Watch app | Recording, the outbox, live SwiftUI | `SendLogWatchCore`, `SendLogHealthCore` | Supabase, CloudKit, Blocks |

Enforcers: the `[[ban]]` lines in `adr.md` (`drover arch-check`), and the compiler: `SendmeterScreens` and the
watch targets do not link what they must not import.

`Features` reaches data through `AppModel` and the feature models only. The four direct `model.repository` calls
(`HistoryView.swift:1170`, `SessionDetailView.swift:437-461`) become `store.read` calls behind the model.

## Deleted

| Where | What |
|---|---|
| `Sources/Data` | `Repositories.swift`, `SupabaseService.swift`, `RealtimeService.swift`. The row types move into `Core/Store` as its record types |
| `Sources/Core` | `OfflineQueue`, `DirectWriteReplay`, `MutationRecoveryCoordinator`, `WorkspaceSyncCoordinator`, `DeltaCursor`, `BackgroundSyncEngine`, `RealtimeListReconciler`, `AuthRecovery`, `AuthDiagnostics`, `AccountScopedFetch`, `PurgeGeneration*`, `SignOutQueuePolicy`, `QueueUploadCoordination`, `MutationSyncStatus`, `PendingSessionWritePolicy`, `RefreshSlicePlan`, `ForegroundRefreshPolicy`, `SessionFreshness`, `AppleAuthNonce`, `LocalCacheStore`, `CachedWorkspace`, `CachePreparation`, `CacheSnapshotRead`, `LocalCacheRepair`, `PendingRecordingOverlay`, most of `RecordingEditCoordinator` |
| `Sources/Core`, kept and simplified | `HealthMetricReconciliation` (window logic stays, server plan goes), `TindeqSessionMerge` (the plan stays, the "not uploaded" refusal goes), `LiveWorkoutMirror` (the server source goes), `DeleteAccountConfirmationGate` (becomes the erase gate) |
| `Sources/Features/Auth`, `App` | `LoginView`, the password recovery view, the boot states `signedOut` and `signedIn` |
| Watch app | `SupabaseService`, `AuthManager`'s relay, `WatchSessionStore`, `Repo`, `HealthRepository`, `LiveWorkoutSync`, `LiveWorkoutTerminalRetry`, `UploadQueueEngine` and its three queues (one small outbox replaces them), `SupabaseConfig.plist` |
| `SendLogWatchCore` | `BackendFailureReason`, `UploadErrorPolicy`, `SessionRelay`, `QueueRetrySchedule`, `TagFetchPolicy`, `Quarantine*`, `WatchHealthReconcile`, `SyncFreshness` |
| Repo | `supabase/`, `scripts/apply-migrations.mjs`, `scripts/migration-status.mjs`, `scripts/migration-safety.mjs`, `scripts/test-health-precedence-race.sh`, `supabase-tests.yml`, `deploy-migrations.yml`, the Supabase entries in `.gitleaks.toml`, `docs/mcp-e2e-verification.md` |
| `mcp/` | `auth.ts`, the Supabase half of `transport.ts`, `config.ts`'s URL and key, the `@supabase/supabase-js` dependency |
| Entitlements | Associated domains now; Sign in with Apple when the import window closes. Added: iCloud (CloudKit, iCloud Documents), push |
