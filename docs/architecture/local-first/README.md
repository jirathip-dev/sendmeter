# Local-first Sendmeter (#1045)

## Summary

Decision: all data lives in one SQLite file on the iPhone (GRDB, already in the app), with today's table and column names. iCloud sync is an opt-in switch on Apple's CKSyncEngine and the user's private database; the watch hands finished records to the phone; the MCP server reads a JSON export folder. Supabase is only read, once, for the import; the app's minimum iOS rises to 26.
Slices: 31 issues in 6 groups: store (5), watch handoff (3), cut-over and Supabase removal (7), sync (3), export and MCP (2), screens on Blocks (10), plus one dated clean-up 90 days after the first local-first TestFlight build. The screens wait for two Blocks fixes (B1, B2); the watch stays plain SwiftUI until a third (B3).
Open questions: none. The owner's four answers (iOS 26 minimum, the three Blocks issues, the 90-day import window, no delete button) are written in.

## Read in this order

| File | What |
|---|---|
| `adr.md` | The question, the options, the decisions, the consequences, the owner's actions, the `arch.toml` lines |
| `usage.md` | How the calling code reads: boot, a write, a screen, the sync switch, the watch, the export |
| `shapes.md` | Every table and synced record, the watch envelope, the export format |
| `sync.md` | The sync statechart and the conflict rules |
| `boundaries.md` | Which module may import which, and what is deleted |
| `blocks.md` | What was run against Blocks v2.0, what works, the three gaps (B1 to B3) |
| `migration.md` | The issues to file, in order |

## What was run

Read on staging `8ed4a064`. Blocks at tag `v2.0` (`b1a9c991`). Host: macOS 27.2, Swift 6.4.2.

| Claim | Command | Exit |
|---|---|---|
| SwiftPM resolves the tag `v2.0` as `exact: "2.0.0"` | `swift test` in a scratch package pinning it | 0 |
| A screen decoded on the device (stat, chart, one app kind) draws with the app's own palette and no server | the same `swift test`: 1 test, 0 failures (macOS) | 0 |
| A screen cannot be built as typed Swift values outside the package | `swift build --target InitProbe` with `Screen(title:)` | 1 |
| BlocksUI does not compile for iOS | `swift build --target BlocksUI --triple arm64-apple-ios26.0-simulator` | 1 |
| `Blocks` (types) compiles for watchOS 26, BlocksUI does not | `swiftc -emit-module` / `-typecheck` against the watch simulator SDK | 0 / 1 |

Not run, and not claimed: CloudKit, HealthKit, WatchConnectivity delivery, iCloud Drive and signing. They are
device-only (`CLAUDE.md`, verification ladder 6). Each slice that touches one says so in `migration.md`.
