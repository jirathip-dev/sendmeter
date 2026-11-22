# Data shapes (#1047)

Two kinds of data, kept apart:

| Kind | Examples | Lives in | Syncs to private iCloud |
|---|---|---|---|
| Domain values | `Layout`, `Hold`, `LightFrame`, `ImportPreview` | memory; defined in `BoardCore` | — |
| User records | `BoardSetup`, `Route`, `Send` | the local-first store (#1045), through `BoardLogbook` | yes, when the user turns sync on |

There is no reference database: no catalogue and no downloaded hardware map. A layout is code.

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

public struct LayoutID: Hashable, Codable, Sendable { public let rawValue: String }

public struct Layout: Identifiable, Equatable, Sendable {
    public let id: LayoutID
    public let kind: BoardKind
    public let name: String
    public let holds: [Hold]
    public let wiring: WiringRule?
    public let wiringStatus: WiringStatus
    public static func of(_ id: LayoutID) -> Layout?
    public static func all(_ kind: BoardKind) -> [Layout]
}

public struct GridCell: Hashable, Comparable, Codable, Sendable {
    public let column: Int
    public let row: Int
}

public struct Hold: Identifiable, Equatable, Sendable {
    public var id: GridCell { cell }
    public let cell: GridCell
    public let point: BoardPoint
    public let label: String
}

public struct BoardPoint: Equatable, Sendable { public let x, y: Double }
public struct LEDPosition: Hashable, Codable, Sendable { public let index: Int }
```

- `Angle.init?` accepts 0 to 90 only.
- A **layout** is one hole pattern at one size: `kilter.homewall.7x10.mainline`, `tension.tb2.12x12`,
  `moonboard.2019`. One file per layout in `Boards/`; `Layout.all` collects them.
- A **hold** is a hole, named by its grid cell. Columns and rows use the numbers printed in that
  maker's installation guide, so what the user reads on screen matches the wall. `label` is `A1` to
  `K18` on a MoonBoard and `column-row` elsewhere. `point` is where to draw the dot.
- MoonBoard layouts differ only by year (2016, Masters 2017, Masters 2019, 2024, Mini 2020, Mini 2025)
  and row count (18 or 12). The year names the wall and scopes its routes.

`BoardDescriptor` says what a board *kind* is; one per kind:

```swift
public struct BoardDescriptor: Sendable {
    public let kind: BoardKind
    public let displayName: String
    public let wire: WireProtocol
    public let scan: ScanFilter
    public let defaultAngles: [Angle]
    public let roles: [HoldRole]
    public let roleColors: [HoldRole: RGB]
    public let imports: [ImportFormat]
    public static func of(_ kind: BoardKind) -> BoardDescriptor
}

public enum WireProtocol: Sendable { case aurora, moonBoardASCII }
```

`roleColors` are Sendmeter's own choice, sent as RGB. The defaults follow the colours climbers already
know on that board and are confirmed on a real one.

## The LED map

```swift
public enum WiringStatus: String, Sendable { case fromGuide, checkedOnWall }

public struct WiringRule: Equatable, Codable, Sendable {
    public let start: Corner
    public let runsAlong: Axis
    public let strands: Int
    public let ledsPerHold: Int
    public let firstIndex: Int
}

public enum LEDMapSource: Equatable, Codable, Sendable {
    case unconfirmed
    case rule(WiringRule, confirmedAt: Date)
    case taught([TaughtLED])
}

public struct TaughtLED: Hashable, Codable, Sendable {
    public let cell: GridCell
    public let led: LEDPosition
}

public struct LEDMap: Equatable, Sendable {
    public init?(layout: Layout, source: LEDMapSource)
    public func leds(behind cell: GridCell) -> [LEDPosition]
    public func cell(lit led: LEDPosition) -> GridCell?
}
```

- A `WiringRule` is the threading order as data: where the string starts, which way it runs, how many
  strands and LEDs per hold. `Layout.wiring` is the rule written from the maker's guide, or `nil`.
- `Layout.wiringStatus` is a property of the shipped rule: `fromGuide` until a real wall of that layout
  has confirmed it, then `checkedOnWall` (changed in a PR that names the wall).
- `LEDMapSource` is a property of the *user's* wall. `LEDMap.init?` returns `nil` for `.unconfirmed`,
  so no frame can be built from an unconfirmed map.

## Route

```swift
public enum HoldRole: String, Codable, Sendable, CaseIterable { case start, hand, finish, foot }

public struct RouteHold: Hashable, Codable, Sendable {
    public let cell: GridCell
    public let role: HoldRole
}

public enum RouteHolds: Equatable, Codable, Sendable {
    case unknown
    case marked([RouteHold])
}

public enum RecordOrigin: Equatable, Codable, Sendable {
    case sendmeter
    case imported(ImportFormat.Kind)
}

public struct RouteRef: Hashable, Codable, Sendable { public let id: UUID }

public struct Route: Identifiable, Equatable, Codable, Sendable {
    public var id: RouteRef { ref }
    public let ref: RouteRef
    public let board: BoardKind
    public var layout: LayoutID?
    public var name: String
    public var setter: String?
    public var grade: Grade?
    public var angle: Angle?
    public var holds: RouteHolds
    public var note: String
    public let origin: RecordOrigin
    public let createdAt: Date
    public var updatedAt: Date
}

public struct Grade: Hashable, Comparable, Codable, Sendable {
    public let rank: Int
    public let label: String
    public init?(label: String)
}
```

- `RouteHolds.unknown` is a name-only route: what an imported logbook row creates. It is listed and
  logged against, never lit. Marking its holds turns it into `.marked`.
- `.marked` can only be built with at least one start and one finish hold. `RouteDraft` is the editor's
  value; `draft.named(_:grade:)` refuses an unlightable draft.
- `layout` is `nil` only on a name-only route whose wall is not known.
- `Grade.rank` is one ladder for every board (the Font and V scales side by side), so the logbook can
  compare a MoonBoard send with a Kilter one.
- MoonBoard routes use `start`, `hand` and `finish` only; its descriptor's `roles` leaves out `foot`.
- `RouteRef` is what #1048 attaches to an attempt.

## Setup

```swift
public struct BoardSetup: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var layout: LayoutID
    public var angle: Angle
    public var angleIsAdjustable: Bool
    public var ledsAboveHolds: Bool
    public var ledMap: LEDMapSource
    public var updatedAt: Date
}
```

`ledsAboveHolds` applies to MoonBoard only. The LED map is part of the synced setup, so a wall taught
on one phone is ready on the user's next one.

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
    public let board: BoardKind
    public let setup: BoardSetup.ID?
    public let angle: Angle?
    public let climbedAt: Date
    public let day: String
    public var outcome: SendOutcome
    public var grade: Grade?
    public var quality: Int?
    public var mirrored: Bool
    public var note: String
    public var sessionID: UUID?
    public let origin: RecordOrigin
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
    public let holds: RouteHolds
}
```

- **The logbook link.** `sessionID` is the id of the logbook `Session` the send belongs to. A send
  logged while a workout is live takes that workout's `sessionID`; otherwise it is `nil` and the
  logbook files it under `day`. Imported sends have no session. #1048 later adds the attempts in between.
- A flash is `.sent(tries: 1)`. `quality` is 1 to 5. `tries` is at least 1; the initialiser refuses less.
- `setup` and `angle` are optional because an imported row may name no wall or angle; a send logged in
  Sendmeter always has both.
- `RouteSnapshot` is why a send still reads correctly after its route is edited or deleted.
- `updatedAt` is for the last-writer-wins rule #1045 will set.

What the local-first store (#1045) must provide, and nothing more:

```swift
public protocol BoardLogbook: Sendable {
    func setups() async throws -> [BoardSetup]
    func save(_ setup: BoardSetup) async throws
    func delete(setup: BoardSetup.ID) async throws
    func routes(matching: RouteFilter) async throws -> [Route]
    func save(_ route: Route) async throws
    func delete(route: RouteRef) async throws
    func sends(matching: SendFilter) async throws -> [Send]
    func save(_ send: Send) async throws
    func delete(send: Send.ID) async throws
    func apply(_ plan: ImportPlan) async throws -> ImportResult
}
```

Three record types join its sync schema: board setup, route, send. Every `save` is an upsert by id;
`apply` inserts only the plan's records whose id is absent, in one transaction.

## Import

```swift
public enum ImportFormat: Equatable, Sendable {
    case auroraExport(board: BoardKind)
    case moonLogbookCSV
    public enum Kind: String, Codable, Sendable { case auroraExport, moonLogbookCSV }
}

public enum BoardImport {
    public static func recognise(_ bytes: Data) -> ImportFormat.Kind?
    public static func read(_ bytes: Data, as format: ImportFormat, onto setup: BoardSetup?) throws -> ImportPreview
}

public struct ImportPreview: Equatable, Sendable {
    public let routes: [Route]
    public let sends: [Send]
    public let skipped: [SkippedEntry]
    public let notImported: [String: Int]
    public func plan(excluding existing: Set<UUID>) -> ImportPlan
}

public struct SkippedEntry: Equatable, Sendable {
    public let what: String
    public let reason: SkipReason
}

public enum SkipReason: Equatable, Sendable {
    case missingField(String), unreadableDate, unknownRole(String)
    case holdOffGrid, layoutNotSupported(String), coordinatesNotProven
}

public enum ImportError: Error, Equatable, Sendable { case notThisFormat, empty, tooLarge }

public struct ImportPlan: Equatable, Sendable { public let routes: [Route]; public let sends: [Send] }
public struct ImportResult: Equatable, Sendable { public let routesAdded, sendsAdded: Int }
```

`read` validates at the edge and returns only typed values; a bad entry becomes a `SkippedEntry`, a
file of the wrong kind throws. Ids are derived from content (`imports.md`), so the same file always
yields the same preview.

## Lighting

```swift
public struct RGB: Hashable, Codable, Sendable { public let red, green, blue: UInt8 }

public struct Lamp: Hashable, Sendable {
    public let led: LEDPosition
    public let role: HoldRole
    public let color: RGB
}

public struct LightFrame: Equatable, Sendable {
    public let lamps: [Lamp]
    public static let clear: LightFrame
}

public enum LightPlan: Equatable, Sendable {
    case ready(LightFrame)
    case blocked(LightBlock)
}

public enum LightBlock: Equatable, Sendable {
    case holdsUnknown
    case wiringUnconfirmed
    case otherLayout(LayoutID?)
    case offThisWall([GridCell])
}

public enum Lighting {
    public static func plan(_ route: Route, on setup: BoardSetup) -> LightPlan
    public static func encoder(for setup: BoardSetup, link: LinkTraits) -> any LightingEncoder
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

`Lighting.plan` is the one gate between a route and the wall: every reason a route cannot be lit is a
`LightBlock` the screen can show. `AuroraEncoder(apiLevel:ledsPerHold:)` and
`MoonBoardEncoder(rows:ledsAboveHolds:)` are the two encoders; `writes(for:)` returns the chunks in
order, each at most 20 bytes.
