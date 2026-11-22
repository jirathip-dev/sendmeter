# Callers' usage

How the code that uses the core reads. Sketches, not final signatures. The pattern is the same everywhere:
something happens, the host sends an event with the time, the core answers with effects, the host carries them
out.

## A screen (Rust, `sm-screens`: pure, host-tested)

```rust
// crates/sm-screens/src/screens/today.rs
pub const ROUTE: &str = "today";

pub struct Input { pub readiness: Option<Readiness>, pub kind: SessionKind, pub week: Week, pub ticks: Vec<Tick>, pub can: Abilities }

pub fn build(i: &Input) -> Block {
    Screen::new().id("today").title("Today").large(true)
        .actions(vec![open("Settings", "gearshape", "settings")])
        .blocks(vec![
            readiness_tiles(i.readiness.as_ref()),            // score only where the inputs are sealed
            kind_chips(i.kind),
            Button::new("Start session").id("start").style(Primary).action("start").into(),
            week_section(&i.week),
            last_ticks(&i.ticks),
        ])
        .into()
}

pub fn act(action: &str, values: &Values) -> Option<Intent> {
    match action {
        "start" => Some(Intent::StartSession),
        "kind" => values.one("kind").map(Intent::SetSessionKind),
        _ => None,
    }
}
```

Its test builds an `Input` from the design's sample numbers and compares the result with
`native/SendmeterNative/design/redesign/screens/today.json`. A button a device cannot serve is left out here:

```rust
if i.can.bluetooth { blocks.push(Button::new("Light it").action("light").into()) }
```

## The core answering (Rust, `sm-app`)

```rust
let app = App::open(config)?;

app.handle(Event::Open { route: "today".into() }, stamp);
//  → [Screen { route: "today", json }]

app.handle(Event::Act { route: "today".into(), action: "start".into(), block: None, values: "{}".into() }, stamp);
//  → [Ops { route: "today", json }, Nav(Native(Recording))]       on the phone
//  → [Ops { route: "today", json }, Nav(Push("session/live"))]    on the web

app.handle(Event::Cloud(CloudEvent::Fetched { changed, deleted, more: false }), stamp);
//  → [Ops { route: "today", json }]            a screen that is open is patched; nothing else is told
```

A whole flow is a host test: open a store in memory, send events, assert on effects and on the next screen.

## The phone (Swift)

```swift
@main
struct SendmeterNativeApp: App {
    @State private var core = CoreHost(                       // an actor around the Rust core
        store: .file(LocalStore.defaultPath), can: .phone,
        radios: [TindeqBluetooth(), BoardBluetooth()], cloud: CloudKitTransport(),
        health: HealthKitService(), watch: WatchLink())

    var body: some SwiftUI.Scene {
        WindowGroup { RootTabs(layout: core.layout) }         // the five tabs, from the core
    }
}

// Features/ScreenHost: the only view that knows BlocksUI; it knows no screen
struct ScreenHost: View {
    let route: String
    @Environment(CoreHost.self) private var core

    var body: some View {
        BlocksView(core.shown[route] ?? .loading, source: nil, act: { core.send(.act(route: route, $0)) })
            .appBlocks(AppKinds.all)                          // Features/Kinds/*Kind.swift
            .blocksLook(core.look(scheme))                    // tokens from the core
            .task { core.send(.open(route: route)) }
    }
}

// CoreHost: every effect has one place
func carryOut(_ effect: Effect) {
    switch effect {
    case .screen(let route, let json): shown[route] = decode(json)
    case .ops(let route, let json): try? shown[route]?.apply(decode(json))
    case .nav(let nav): path.go(nav)                          // push, sheet, back, tab, or a native live view
    case .ble(let command): radios.run(command)
    case .cloud(let command): cloud.run(command)
    case .live(let frame): live.frame = frame                 // what the SwiftUI live views draw
    case .watch(let out): watch.send(out)
    case .widget(let payload): ReadinessWidget.write(payload)
    case .pick(let what): picker.present(what)
    case .save(let name, let bytes): export.write(name, bytes)
    case .wake(let ms): timer.fire(after: ms) { self.send(.tick) }
    }
}
```

A platform class is the same three lines in each direction:

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

## The iCloud link on the phone (Swift, `Data/CloudKit`)

```swift
final class CloudKitTransport: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e): core.send(.cloud(.engineState(encode(e.stateSerialization))))
        case .accountChange(let e): core.send(.cloud(.account(status(e))))
        case .fetchedRecordZoneChanges(let e):
            core.send(.cloud(.fetched(changed: e.modifications.map(record), deleted: e.deletions.map(name), more: false)))
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

`record`, `saved`, `failed` and `batch` are the mechanical conversions the fixtures test. Sealed fields go
through `encryptedValues`, the rest through plain keys.

## The web (TypeScript)

```ts
// web/src/main.ts
const core = new Worker(new URL("./worker.ts", import.meta.url), { type: "module" });
const can = { bluetooth: "bluetooth" in navigator, health: false, watch: false, saved, live: "blocks", sync: "signIn" };
const send = (event: Event) => core.postMessage({ event, stamp: stamp() });

const shell = mount({                                          // Blocks' shell, on a local source (blocks #354)
  root, layout, blocks: kinds, theme,
  local: { open: (route) => send({ open: { route } }), act: (route, a) => send({ act: { route, ...a } }) },
});

core.onmessage = ({ data: effects }: MessageEvent<Effect[]>) => {
  for (const e of effects) {
    if ("screen" in e) shell.screen(e.screen.route, JSON.parse(e.screen.json));
    else if ("ops" in e) shell.ops(e.ops.route, JSON.parse(e.ops.json));
    else if ("nav" in e) shell.go(e.nav);
    else if ("ble" in e) ble.run(e.ble);
    else if ("cloud" in e) cloud.run(e.cloud);
    else if ("pick" in e) files.pick(e.pick);
    else if ("save" in e) files.download(e.save.name, e.save.bytes);
    else if ("wake" in e) setTimeout(() => send("tick"), e.wake.after_ms);
  }
};
```

```ts
// web/src/cloud.ts: the whole transport is this shape
export async function run(command: CloudCommand) {
  if ("fetch" === command) {
    const r = await db.fetchRecordZoneChanges({ zoneID, syncToken });
    send({ cloud: { fetched: { changed: r.records.map(fromCloudKit), deleted: r.deleted, more: r.moreComing } } });
  } else if ("send" in command) {
    const r = await db.saveRecords(command.send.saves.map(toCloudKit), { zoneID });   // every field with its type
    send({ cloud: { sent: { saved: r.records.map(saved), failed: (r.errors ?? []).map(failed) } } });
  }
  // signIn, signOut, start, stop, deleteZone, forget: the same, one call each
}

// web/src/ble.ts
if ("scan" in command) {
  const device = await navigator.bluetooth.requestDevice(filterFor(command.scan));     // the browser's chooser
  send({ ble: { found: { device: ref(device), name: device.name, services: [] } } });
}
```

## Sync, as the rest of the app sees it

There is no sync API to call. Settings is a screen like any other:

```rust
// crates/sm-screens/src/screens/settings.rs
"sync-on" => Some(Intent::Sync(SyncAsk::TurnOn)),        // phone: the switch; web: the sign-in button
"sync-off" => Some(Intent::Sync(SyncAsk::TurnOff)),
"sync-merge" => Some(Intent::Sync(SyncAsk::Merge)),
```

`sm-app` feeds the ask to `sm-sync::reduce`, carries the new state into the Settings input, and returns the
`CloudCommand`s as effects. A write anywhere marks its row pending through the store's triggers; nobody calls
"sync this".

## A write

```rust
store.write(stamp, |tx| tx.log_session(&draft))?;        // one call, one transaction; returns the stored row
store.write(stamp, |tx| tx.purge_session(id))?;          // a former RPC
store.write(stamp, |tx| tx.ingest(&watch_record))?;      // idempotent by id
```

Only `sm-app` and `sm-sync` call the store. A screen never does: it returns an `Intent`.

## Boards

#1047's usage is kept, in Rust:

```rust
match Lighting::plan(&route, &setup) {
    LightPlan::Ready(frame) => link.handle(LinkEvent::Light(Lighting::encoder(&setup, traits).writes(&frame)?, token)),
    LightPlan::Blocked(why) => Intent::Explain(why),
}
let preview = BoardImport::read(&bytes, ImportFormat::AuroraExport(BoardKind::Tension), Some(&setup))?;
```
