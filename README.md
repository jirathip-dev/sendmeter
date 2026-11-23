# Sendmeter

A climbing training tracker: a **native SwiftUI iPhone app** with an **Apple
Watch companion**, backed by **Supabase** (auth + Postgres + realtime). Core
value is numbers — a daily recovery/readiness score (HRV, resting HR, sleep,
weight) and finger-strength force curves from a **Tindeq Progressor** strain
gauge over Bluetooth LE.

**Native-only since #857**: the React/Vite/Capacitor web app and the root npm
package were retired. The removal inventory (what went, what stayed, and who
owns each concern now) is
[docs/architecture/857-removal-inventory.md](docs/architecture/857-removal-inventory.md).

## What's in the repo

| Path | What it is |
|---|---|
| `native/SendmeterNative/` | The phone app, its WidgetKit extension, and the embedded watch app. XcodeGen spec `project.yml`; `SendmeterNative.xcodeproj` is generated, never committed. |
| `native/SendmeterNative/Sources/Core` | `SendmeterCore` SwiftPM package — pure models, metrics, force engine, guided protocol, queues, account-scoped cache. Unit-tested on the host. |
| `ios/App/SendLogWatchCore/` | `SendLogWatchCore` SwiftPM package — watch pure logic (attempt detection, RPE model, Tindeq protocol, hands-free force control). |
| `ios/App/SendLogWatch Watch App/`, `ios/App/SendLogWatchWidgets/` | The watch app and its complications / Smart-Stack widgets (watchOS 10+). |
| `native-plugins/sendlog-health-core/` | `SendLogHealthCore` — readiness/ACWR math and the readiness-widget contract shared by the phone app, watch and widget. |
| `supabase/` | Migrations, SQL regression tests, seed, local stack config. |
| `mcp/` | A separate, package-local, **read-only** MCP server (own `package.json` + lockfile + CI job). |
| `.gatekeeper/`, `scripts/`, `fastlane/` | Gatekeeper's config, baselines and the repo's own gates; the scripts those gates and the migration tooling run; the `native_beta` TestFlight lane. |

## Gates

```bash
./.gatekeeper/run check                      # every gate: the same command CI and drover's done check run
./.gatekeeper/run check --gate local/app     # one gate alone
./.gatekeeper/run list                       # the planned gates, their budgets and why one is skipped
```

Heavy Xcode builds are serialized: **one at a time, never two concurrent
xcodebuilds**. There is no root npm package — `mcp/` keeps its own
package-local commands.

## Docs

- [CLAUDE.md](CLAUDE.md) (also `AGENTS.md`) — contributor guidance, the
  verification ladder, and the environment/data boundaries.
- [native/SendmeterNative/README.md](native/SendmeterNative/README.md) — the
  phone app's architecture.
- [mcp/README.md](mcp/README.md) — the MCP server and its package-local
  commands.
- [docs/testing.md](docs/testing.md) — coverage gates and floors.
- [docs/security.md](docs/security.md),
  [docs/dependency-security.md](docs/dependency-security.md) — security gates.
- [docs/app-store-checklist.md](docs/app-store-checklist.md),
  [docs/app-review-notes.md](docs/app-review-notes.md) — App Store submission.

`main` and TestFlight are human-only; work happens on `staging`-cut branches.
Device-only behavior (HealthKit runtime, Bluetooth/Tindeq, Live Activities,
passkeys, WatchConnectivity) cannot be verified in a simulator — flag it
instead of claiming it verified.
