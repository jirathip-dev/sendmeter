# Callers' usage

How the code that uses the new pieces reads. Sketches, not final signatures.

## Boot: no login gate

```swift
@main
struct SendmeterNativeApp: App {
    @State private var model = AppModel(
        store: LocalStore.openDefault(),                       // Core; opens off the main thread
        sync: SyncController(transport: CloudKitTransport()),  // Data/CloudKit behind Core's protocol
        watch: WatchLink(),
        export: ExportWriter()
    )

    var body: some Scene {
        WindowGroup {
            switch model.boot {
            case .opening: SplashView()
            case .ready: MainTabView()
            case .importOffered(let source): LegacyImportView(source)   // only when an old session is found
            case .storeFailed(let reason): StoreFailureView(reason)
            }
        }
    }
}
```

`AppBootState.signedOut` and `.signedIn` are gone. So is every `currentUserID` guard.

## Reading

```swift
let workspace = try await store.read { try Workspace.fetch($0, today: today) }   // sessions, phases, health, …
for await workspace in store.observe(Workspace.self) { self.workspace = workspace }

let samples = try await store.read { try $0.samples(of: recording.id) }           // heavy rows on demand
```

## Writing: one call, one transaction, nothing pending

```swift
let session = try await store.write { try $0.logSession(draft, on: today) }
try await store.write { try $0.softDeleteSession(id) }
try await store.write { try $0.purgeSession(id) }                     // the purge_session RPC, on the device
try await store.write { try $0.mergeTindeqSessions(ids, into: target) }
try await store.write { try $0.renameTag(old, to: new) }
try await store.write { try $0.upsertHealthDay(day, writer: .phone, now: now, timeZone: zone) }
```

A write returns the stored value or throws. There is no queue, no `pending`, no `rejected`, no "Retry now".

## A screen

```swift
// Sources/Screens/PhasesScreen.swift      (SendmeterScreens: pure, host-tested)
public struct PhasesScreen: AppScreen {
    public struct Input: Equatable, Sendable { var periods: [PhasePeriod]; var current: PhaseID; var today: String }

    public func build(_ input: Input) -> Block {
        .screen(Screen(id: "phases", title: "Phases", blocks: [
            .stat(Stat(label: "Current", value: .text(PhaseCatalog.name(input.current)), tone: .accent)),
            .list(List(rows: input.periods.map(row))),
            .button(Button(label: "Switch phase", action: "switch")),
        ]))
    }
}

// Sources/Features/Phases/PhasesHost.swift      (app target)
ScreenHost(PhasesScreen(), input: model.phasesInput) { action in
    switch action.action {
    case "switch": path.append(SwitchPhaseScreen())
    case "open-period": path.append(PeriodScreen(id: action.values["id"]))
    default: break
    }
}
```

`ScreenHost` is the one place that knows BlocksUI:

```swift
BlocksView(screen.build(input), source: nil, act: handle)
    .appBlocks(AppKinds.all)            // generated from Features/Kinds/*Kind.swift
    .blocksLook(.sendmeter(scheme))     // Look(palette: from SendmeterPalette, tiles: nil)
    .screenTitle(false)                 // the app keeps its own navigation title
```

`Screen(id:title:blocks:)` needs Blocks gap 2 (`blocks.md`); it does not compile against v2.0.

## An app kind (a chart Blocks has no kind for)

```swift
// Sources/Features/Kinds/ForceCurveKind.swift
enum ForceCurveKind: AppKind {
    static let type = "force-curve"
    static func draw(_ block: JSONValue) -> AnyView { AnyView(NativeForceCurveCard(recordingID: block.id)) }
}
```

Live surfaces (recording, the gauge, the routine runner) are plain SwiftUI views pushed by an action handler.

## The sync switch

```swift
Toggle("Sync with iCloud", isOn: model.sync.isOnBinding)      // off by default
SyncStatusRow(state: model.sync.state)                        // SyncState, from sync.md

await sync.turnOn()          // Off → Starting → On | SignedOut
await sync.turnOff()         // keeps both copies
await sync.deleteCloudCopy() // confirmed by the caller first
```

## The watch

```swift
// phone
watch.onRecord = { record in
    try await store.write { try $0.ingest(record, now: .now, timeZone: .current) }    // idempotent by record.id
    return WatchRecordAck(stored: [record.id])
}
store.onChange(of: WatchSnapshot.self) { watch.publish($0) }                          // application context

// watch
try outbox.put(.workout(bundle))        // file on disk first, then transferFile; removed on ack
let snapshot = link.snapshot            // tags, presets, phase, loads, readiness: no network
```

## The import (existing users, once)

```swift
let source = LegacyImport.findSavedSession()                  // nil: offer email/password or Apple, or skip
for try await progress in LegacyImport(source, into: store).run() { show(progress) }   // resumes by family
```

## The export and the MCP server

```swift
try await export.writeIfChanged(from: store, to: ExportLocation.current(sync: sync.state))
```

```ts
// mcp/src/index.ts
const store = createExportStore(process.env.SENDMETER_EXPORT_DIR ?? defaultExportDir());
const server = buildServer(async () => store);      // the six tools and their queries do not change
```
