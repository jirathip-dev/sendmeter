# Data shapes (#1047)

Three kinds of data, kept apart:

| Kind | Examples | Lives in | Syncs to iCloud |
|---|---|---|---|
| Domain values | `Route`, `Hold`, `LightFrame` | memory; defined in `BoardCore` | — |
| User records | `BoardSetup`, the user's routes, `Send` | the local-first store (#1045), through `BoardLogbook` | yes, when the user turns sync on |
| Reference data | catalogue, hardware map | their own SQLite files in Application Support | never; excluded from backup |

All `BoardCore` types are `public`, so each declares `Sendable` explicitly. Dates that become day keys
go through the repo's Gregorian `DateSupport`.

## Board, layout, hold, angle

```swift
public enum BoardKind: String, Codable, Sendable, CaseIterable {
    case kilter, tension, moonBoard = "moonboard"
}

public struct Angle: Hashable, Comparable, Codable, Sendable {
    public let degrees: Int
    public init?(degrees: Int)
}

public struct LayoutID: Hashable, Codable, Sendable {
    public let kind: BoardKind
    public let value: Int
}

public struct Layout: Identifiable, Equatable, Sendable {
    public let id: LayoutID
    public let name: String
    public let sizes: [BoardSize]
    public let holdSets: [HoldSet]
    public let canMirror: Bool
}

public struct BoardSize: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let edges: Edges
}

public struct HoldSet: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
}

public struct Edges: Equatable, Codable, Sendable {
    public let left, right, bottom, top: Int
}

public struct HoldID: Hashable, Codable, Sendable {
    public let rawValue: Int
}

public struct Hold: Identifiable, Equatable, Sendable {
    public let id: HoldID
    public let point: BoardPoint
    public let led: LEDPosition
    public let holdSet: HoldSet.ID?
    public let label: String?
}

public struct BoardPoint: Equatable, Sendable { public let x, y: Double }
public struct LEDPosition: Hashable, Sendable { public let index: Int }
```

- `Angle.init?` accepts 0 to 90 only.
- A `HoldID` means something only inside its layout. On Kilter and Tension it is the placement id from
  the hardware map. On MoonBoard it is the LED index of the cell on that grid.
- MoonBoard needs no hardware data: `MoonBoardGrid(rows: .standard18 | .mini12)` computes its 198 or
  132 holds, each labelled `A1` to `K18`. Its layouts are constants in the MoonBoard descriptor (2016,
  Masters 2017, Masters 2019, 2024, Mini 2020, Mini 2025); the year scopes routes and names the wall,
  and only the row count affects lighting. Every cell is selectable in v1.

`BoardDescriptor` is the one place that says what a board is. One file per board in `Boards/`:

```swift
public struct BoardDescriptor: Sendable {
    public let kind: BoardKind
    public let displayName: String
    public let wire: WireProtocol
    public let scan: ScanFilter
    public let defaultAngles: [Angle]
    public let ledsPerHold: Int
    public let catalogue: CatalogueAvailability
    public static func of(_ kind: BoardKind) -> BoardDescriptor
}

public enum WireProtocol: Sendable { case aurora, moonBoardASCII }
public enum CatalogueAvailability: Sendable { case off, snapshot }
```

`catalogue` is the compile-time allow-list from the ADR: `.snapshot` for Kilter and Tension, `.off` for
MoonBoard, unless the owner answers otherwise.

## Route

```swift
public enum HoldRole: String, Codable, Sendable, CaseIterable { case start, hand, finish, foot }

public struct RouteHold: Hashable, Codable, Sendable {
    public let hold: HoldID
    public let role: HoldRole
}

public enum RouteSource: String, Codable, Sendable { case catalogue, user }

public struct RouteRef: Hashable, Codable, Sendable {
    public let source: RouteSource
    public let layout: LayoutID
    public let key: String
}

public struct Route: Identifiable, Equatable, Sendable {
    public var id: RouteRef { ref }
    public let ref: RouteRef
    public let name: String
    public let setter: String?
    public let note: String
    public let holds: [RouteHold]
    public let setAngle: Angle?
    public let createdAt: Date?
}

public struct RouteStats: Equatable, Sendable {
    public let angle: Angle
    public let grade: Grade?
    public let isBenchmark: Bool
    public let ascents: Int
    public let quality: Double?
}

public struct Grade: Hashable, Comparable, Codable, Sendable {
    public let rank: Int
    public let label: String
}
```

- `RouteRef.key` is the catalogue's climb id for a catalogue route and a local UUID string for a user
  route. `RouteRef` is what #1048 attaches to an attempt.
- A catalogue route has stats per angle; a user route has the one grade its author gave it.
- `Grade.rank` is one ladder for every board (the Font and V scales side by side), so the logbook can
  compare a MoonBoard send with a Kilter one. Catalogue difficulty numbers map onto it at import.
- MoonBoard routes use `start`, `hand` and `finish` only; the encoder refuses `foot` there.
- `RouteDraft` is the editor's value: it toggles holds and can only be saved through `named(_:grade:)`,
  which refuses a draft with no start or no finish hold, so an unlightable route cannot be stored.

## Setup

```swift
public struct BoardSetup: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var geometry: BoardGeometry
    public var angle: Angle
    public var angleIsAdjustable: Bool
    public var updatedAt: Date
    public var kind: BoardKind { geometry.kind }
    public var layout: LayoutID { geometry.layout }
}

public enum BoardGeometry: Equatable, Codable, Sendable {
    case aurora(kind: BoardKind, layout: Int, size: Int, holdSets: [Int], mirrored: Bool)
    case moonBoard(setup: MoonBoardSetup, ledsAboveHolds: Bool)
}

public enum MoonBoardSetup: String, Codable, Sendable, CaseIterable {
    case original2016, masters2017, masters2019, standard2024, mini2020, mini2025
    public var rows: MoonBoardRows { get }
}
```

`BoardGeometry.aurora` accepts only `.kilter` or `.tension`; its initialiser refuses `.moonBoard`.

Device-local, in the same place `KnownProgressorStore` keeps the Tindeq (not synced):

```swift
public struct KnownBoard: Equatable, Codable, Sendable {
    public let setup: BoardSetup.ID
    public let peripheral: UUID
    public let traits: LinkTraits
}

public struct LinkTraits: Equatable, Codable, Sendable {
    public let auroraAPILevel: Int?
    public let writesNeedResponse: Bool
}
```

## Send

```swift
public struct Send: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let route: RouteSnapshot
    public let setup: BoardSetup.ID
    public let angle: Angle
    public let climbedAt: Date
    public let day: String
    public var outcome: SendOutcome
    public var gradeAtSend: Grade?
    public var proposedGrade: Grade?
    public var quality: Int?
    public var note: String
    public var sessionID: UUID?
    public var updatedAt: Date
}

public enum SendOutcome: Equatable, Codable, Sendable {
    case sent(tries: Int)
    case attempted(tries: Int)
}

public struct RouteSnapshot: Equatable, Codable, Sendable {
    public let ref: RouteRef
    public let name: String
    public let setter: String?
    public let holds: [RouteHold]
}
```

- **The logbook link.** `sessionID` is the id of the logbook `Session` the send belongs to. A send
  logged while a workout is live takes that workout's `sessionID`; otherwise it is `nil` and the
  logbook files it under `day`. #1048 later adds the attempts in between.
- A flash is `.sent(tries: 1)`. `quality` is 1 to 5. `tries` is at least 1; the initialiser refuses less.
- `RouteSnapshot` is why a send still reads correctly after the catalogue is refreshed or deleted.
- `updatedAt` is for the last-writer-wins rule #1045 will set.

What the local-first store (#1045) must provide, and nothing more:

```swift
public protocol BoardLogbook: Sendable {
    func setups() async throws -> [BoardSetup]
    func save(_ setup: BoardSetup) async throws
    func delete(setup: BoardSetup.ID) async throws
    func userRoutes(on layout: LayoutID) async throws -> [Route]
    func save(_ route: NamedRouteDraft) async throws -> Route
    func delete(route: RouteRef) async throws
    func sends(matching: SendFilter) async throws -> [Send]
    func save(_ send: Send) async throws
    func delete(send: Send.ID) async throws
}
```

Three record types join its sync schema: board setup, user route, send. Every `save` is an upsert by id.

## Lighting

```swift
public struct RGB: Hashable, Sendable { public let red, green, blue: UInt8 }

public struct Lamp: Hashable, Sendable {
    public let led: LEDPosition
    public let role: HoldRole
    public let color: RGB
}

public struct LightFrame: Equatable, Sendable {
    public let lamps: [Lamp]
    public static let clear: LightFrame
}

public protocol LightingEncoder: Sendable {
    func writes(for frame: LightFrame) throws -> [Data]
}

public enum LightingError: Error, Equatable, Sendable {
    case positionOutOfRange(LEDPosition)
    case roleNotSupported(HoldRole)
    case tooManyLamps(Int)
}
```

`AuroraEncoder(apiLevel:ledsPerHold:)` and `MoonBoardEncoder(rows:ledsAboveHolds:)` are the two
conformers. `writes(for:)` returns the chunks in order, each at most 20 bytes.

## Reference data: the two databases

Sendmeter's own schema, written by the importers. Nothing above the stores sees a snapshot's schema.

`Boards/hardware.sqlite` (Kilter and Tension only; a few megabytes):

```sql
CREATE TABLE layout   (kind TEXT, id INTEGER, product_id INTEGER, name TEXT, can_mirror INTEGER,
                       PRIMARY KEY (kind, id));
CREATE TABLE size     (kind TEXT, id INTEGER, product_id INTEGER, name TEXT,
                       edge_left INTEGER, edge_right INTEGER, edge_bottom INTEGER, edge_top INTEGER,
                       PRIMARY KEY (kind, id));
CREATE TABLE hold_set (kind TEXT, id INTEGER, name TEXT, PRIMARY KEY (kind, id));
CREATE TABLE layout_size_set (kind TEXT, layout_id INTEGER, size_id INTEGER, set_id INTEGER,
                       PRIMARY KEY (kind, layout_id, size_id, set_id));
CREATE TABLE hold     (kind TEXT, id INTEGER, layout_id INTEGER, set_id INTEGER, x REAL, y REAL,
                       mirrored_id INTEGER, PRIMARY KEY (kind, id));
CREATE TABLE led      (kind TEXT, size_id INTEGER, hold_id INTEGER, position INTEGER,
                       PRIMARY KEY (kind, size_id, hold_id));
CREATE TABLE role     (kind TEXT, product_id INTEGER, id INTEGER, role TEXT,
                       led_color TEXT, screen_color TEXT, PRIMARY KEY (kind, id));
CREATE TABLE grade    (kind TEXT, difficulty INTEGER, label TEXT, rank INTEGER,
                       PRIMARY KEY (kind, difficulty));
CREATE TABLE meta     (key TEXT PRIMARY KEY, value TEXT);
```

`Boards/catalogue-<kind>-<layout>.sqlite` (one per layout a setup uses):

```sql
CREATE TABLE route (
    key TEXT PRIMARY KEY, name TEXT NOT NULL, setter TEXT, note TEXT NOT NULL,
    frames TEXT NOT NULL, set_angle INTEGER, created_at TEXT,
    edge_left INTEGER, edge_right INTEGER, edge_bottom INTEGER, edge_top INTEGER,
    required_sets TEXT NOT NULL
);
CREATE TABLE route_stats (
    key TEXT NOT NULL, angle INTEGER NOT NULL, rank INTEGER, grade_label TEXT,
    is_benchmark INTEGER NOT NULL, ascents INTEGER NOT NULL, quality REAL,
    PRIMARY KEY (key, angle)
) WITHOUT ROWID;
CREATE INDEX route_stats_popular ON route_stats (angle, ascents DESC);
CREATE INDEX route_stats_grade   ON route_stats (angle, rank);
CREATE VIRTUAL TABLE route_search USING fts5 (name, setter, content='route', content_rowid='rowid');
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
```

- `frames` stays the source string (`p<hold>r<role>` repeated); `BoardCore` parses it into
  `[RouteHold]` when a route is opened, with the role table from the hardware map.
- The importer keeps only listed, published, non-hidden, single-frame climbs. That filter is the knob
  for disk size.
- A route fits a setup when its edges lie inside the setup's size and its `required_sets` are all
  installed. That check is a pure function in `BoardCore`.
- `meta` records the source, the snapshot's build time, the import time and the importer version.
- Setter names are public usernames; they are shown on each route, as the snapshot's publisher asks.

The query the tab uses:

```swift
public struct RouteQuery: Equatable, Sendable {
    public var angle: Angle
    public var grades: ClosedRange<Grade>?
    public var text: String
    public var minimumAscents: Int
    public var benchmarksOnly: Bool
    public var sort: RouteSort
}

public enum RouteSort: Sendable { case mostClimbed, newest, easiest, hardest, bestRated }
```
