# Callers' usage

How the code that uses the core reads. Sketches, not final signatures. The pattern is the same everywhere:
something happens, the host sends an event with the time, the core answers with effects, the host carries them
out.

## A screen (Rust, `sm-screens`: pure, host-tested)

```rust
// crates/sm-screens/src/screens/today.rs
pub const ROUTE: &str = "today";

pub struct Input { pub readiness: Option<Readiness>, pub kind: SessionKind, pub week: Week, pub ticks: Vec<Tick> }

pub fn build(i: &Input) -> Block {
    Screen::new().id("today").title("Today").large(true)
        .actions(vec![open("Settings", "gearshape", "settings")])
        .blocks(vec![
            readiness_tiles(i.readiness.as_ref()),
            kind_chips(i.kind),
            Button::new("Start session").id("start").style(Primary).action("start").into(),
            week_section(&i.week),
            last_ticks(&i.ticks),
        ])
        .into()
}

pub fn act(action: &Action) -> Option<Intent> {
    match action.name.as_str() {
        "start" => Some(Intent::StartSession),
        "kind" => action.value("kind").map(Intent::SetSessionKind),
        _ => None,
    }
}
```

Its test builds an `Input` from the design's sample numbers and compares the result with the approved
design's JSON for that screen. Adding a screen is adding this one file: the build script finds it.

## The core answering (Rust, `sm-app`)

```rust
let app = App::open(config)?;

app.handle(Event::Open { route: "today".into() }, stamp);
//  → [Screen { route: "today", json }]

app.handle(Event::Act { route: "today".into(), action: r#"{"name":"start"}"#.into() }, stamp);
//  → [Ops { route: "today", json }, Nav(Live(Recording)), Live(frame), Wake { after_ms: 1000 }]

app.handle(Event::Cloud(CloudEvent::Fetched { changed, deleted }), stamp);
//  → [Ops { route: "today", json }]            a screen that is open is patched; nothing else is told
```

Every call is a plain function call that returns. A whole flow is a host test: open a store in memory, send
events, assert on effects and on the next screen.

## A query and its test (Rust, `sm-store`)

```sql
select id, date, type, duration_min, rpe, load from sessions
where deleted_at is null and date between ?1 and ?2 and (?3 is null or type = ?3)
order by date desc, created_at desc
```

```rust
// crates/sm-store/src/read/sessions.rs — the statement above is queries/sessions_in_week.sql
pub fn sessions_in_week(db: &Db, week: Week, kind: Option<SessionKind>) -> Result<Vec<SessionRow>, StoreError> {
    db.rows(sql::SESSIONS_IN_WEEK, (week.first(), week.last(), kind), SessionRow::read)
}

// crates/sm-store/tests/queries/sessions_in_week.rs
#[test]
fn sessions_in_week() {
    let db = migrated();                                  // in memory, through every real migration
    seed(&db, [session("2026-11-16", Board), session("2026-11-23", Board), deleted("2026-11-17")]);
    let rows = read::sessions_in_week(&db, week_of("2026-11-16"), None).unwrap();
    assert_eq!(dates(&rows), ["2026-11-16"]);
}
```

A query file with no test of its name does not build.

## A write

```rust
store.write(stamp, |tx| tx.log_session(&draft))?;        // one call, one transaction; returns the stored row
store.write(stamp, |tx| tx.purge_session(id))?;          // a former RPC
store.write(stamp, |tx| tx.ingest(&watch_record))?;      // idempotent by id
```

Only `sm-app` and `sm-sync` call the store. A screen never does: it returns an `Intent`. A write marks its
row pending through the store's triggers; nobody calls "sync this".

## The phone (Swift)

```swift
actor CoreHost {                                          // owns the Rust core; the only caller
    private let core: SendmeterCore                       // UniFFI: open, handle
    private let events: AsyncStream<(Event, Stamp)>
    private nonisolated let inbox: AsyncStream<(Event, Stamp)>.Continuation

    nonisolated func send(_ event: Event) { inbox.yield((event, .now())) }     // from any thread, in order

    func run() async {                                    // the one loop: one event at a time
        for await (event, stamp) in events { await carryOut(core.handle(event: event, stamp: stamp)) }
    }

    private func carryOut(_ effects: [Effect]) async {
        for effect in effects {
            switch effect {
            case .screen, .ops, .nav, .live, .pick: await shown.apply(effect)      // main actor
            case .ble(let command): radios.run(command)
            case .cloud(let command): cloud.run(command)
            case .watch(let out): watch.send(out)
            case .widget(let payload): ReadinessWidget.write(payload)
            case .save(let name, let bytes): export.write(name, bytes)
            case .wake(let ms): timer.fire(after: ms) { self.send(.tick) }
            }
        }
    }
}

@MainActor @Observable final class Shown {                // what the views read; decides nothing
    var screens: [String: Block] = [:]
    var path = NavPath()
    var live: LiveFrame?
}

// Features/ScreenHost: the only view that knows BlocksUI; it knows no screen
struct ScreenHost: View {
    let route: String
    @Environment(Shown.self) private var shown
    @Environment(\.core) private var core

    var body: some View {
        BlocksView(shown.screens[route] ?? .loading, source: nil, act: { core.send(.act(route: route, action: $0.json)) })
            .appBlocks(AppKinds.all)                          // Features/Kinds/*Kind.swift
            .blocksLook(shown.look)                           // tokens from the core
            .task { core.send(.open(route: route)) }
    }
}
```

`send` never awaits and never reads state: it stamps the event and queues it. No view or service makes a
decision from a value it captured before an `await`; the decision is made in the core, in order.

A platform class is the same few lines in each direction:

```swift
// Platform/TindeqBluetooth.swift
func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    core.send(.ble(.value(device: ref(p), characteristic: c.uuid.uuidString, bytes: c.value ?? Data())))
}
func run(_ command: BleCommand) { /* scan, connect, subscribe, write: no decision */ }

// Platform/HealthKitService.swift
core.send(.health(HealthDay(date: day, hrvSdnnMs: hrv, restingHr: rhr, sleepHours: sleep, ...)))

// Platform/WatchLink.swift
session.didReceive(file) { core.send(.watch(.record(bytes))) }     // the core stores it, then answers .watch(.ack)
```

## A live view (Swift, `Features/Live`)

```swift
struct LiveForceView: View {
    let frame: LiveFrame                                  // everything it shows; it computes nothing

    var body: some View {
        ViewThatFits(in: .vertical) {                     // full, then without secondary rows; never a ScrollView
            ForceLayout(frame, rows: .all)
            ForceLayout(frame, rows: .primary)
        }
    }
}
```

Its layout test draws it at 375 × 667 points with the fullest `LiveFrame` and asserts the first layout that
fits shows every primary item. The watch's live views have the same test at 40 mm in the watch suite.

## The iCloud link (Swift, `Data/CloudKit`)

```swift
final class CloudKitTransport: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e): core.send(.cloud(.engineState(encode(e.stateSerialization))))
        case .accountChange(let e): core.send(.cloud(.account(status(e))))
        case .fetchedRecordZoneChanges(let e):
            core.send(.cloud(.fetched(changed: e.modifications.map(record), deleted: e.deletions.map(name))))
        case .sentRecordZoneChanges(let e):
            core.send(.cloud(.sent(saved: e.savedRecords.map(saved), failed: e.failedRecordSaves.map(failed))))
        default: break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        batch(from: await core.ask(.cloud(.batchWanted(maxRecords: 100, maxBytes: 900_000))))
    }
}
```

`record`, `saved`, `failed` and `batch` are the mechanical conversions the fixtures test: every field through
`encryptedValues`, the asset column through a `CKAsset` file. `ask` goes through the same queue as `send` and
returns that event's effects.

## Sync, as the rest of the app sees it

There is no sync API to call. Settings is a screen like any other:

```rust
// crates/sm-screens/src/screens/settings.rs
"sync-on" => Some(Intent::Sync(SyncAsk::TurnOn)),
"sync-off" => Some(Intent::Sync(SyncAsk::TurnOff)),
"sync-merge" => Some(Intent::Sync(SyncAsk::Merge)),
```

`sm-app` feeds the ask to `sm-sync::reduce`, carries the new state into the Settings input, and returns the
`CloudCommand`s as effects.

## Boards

#1047's usage is kept, in Rust:

```rust
match Lighting::plan(&route, &setup) {
    LightPlan::Ready(frame) => link.handle(LinkEvent::Light(Lighting::encoder(&setup, traits).writes(&frame)?, token)),
    LightPlan::Blocked(why) => Intent::Explain(why),
}
let preview = BoardImport::read(&bytes, ImportFormat::AuroraExport(BoardKind::Tension), Some(&setup))?;
```
