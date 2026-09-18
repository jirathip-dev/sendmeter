# CLAUDE.md

Guidance for coding agents working in this repo. (This file is read as
repository instructions — keep it true, and fix it when the repo moves.)

## What this is

**Sendmeter** — a climbing training tracker. **Native-only since #857**: the
React/Vite/Capacitor web app, the root npm package, and the Capacitor phone
host were retired. The shipped product is the SwiftUI iPhone app plus its
Apple Watch companion, backed by **Supabase** (auth + Postgres + realtime).

Core value is numbers: a daily recovery/readiness score (HRV, resting HR,
sleep, weight) and finger-strength force curves from a **Tindeq Progressor**
strain gauge over Bluetooth LE.

> Note: the app was renamed from "Send Log" → **Sendmeter** (the App Store name
> was taken). The rename is display-name only — internal identifiers still say
> `sendlog` / `SendLog` (see "Names" below).

### Repo map

- **`native/SendmeterNative/`** — the phone app. `project.yml` is the XcodeGen
  spec; `SendmeterNative.xcodeproj` is **generated, never committed**.
  - Targets: `SendmeterNative` (app, iOS 17+, embeds `SendmeterNativeWidgets`
    and the reused `SendLogWatch Watch App`), `SendmeterNativeTests`,
    `SendmeterNativeUITests`, `SendmeterNativeWidgets`, `SendLogWatch Watch App`,
    `SendLogWatchWidgets`.
  - `Sources/Core` — pure models, metrics, force engine, guided protocol, queue
    and state engines, account-scoped GRDB cache (`SendmeterCore` SwiftPM
    target). `Sources/Data` — Supabase auth + typed PostgREST repositories.
    `Sources/Platform` — CoreBluetooth, HealthKit, WatchConnectivity, weather.
    `Sources/Features` — product screens. `Sources/Shared` + `Sources/Widgets`
    — ActivityKit wire types and the WidgetKit appex. `Sources/App` — lifecycle,
    `AppModel`, design system.
  - `native/SendmeterNative/README.md` is the deep architecture read (account
    isolation contract, cache/LWW rules, watch embedding, quality gates).
- **`ios/App/SendLogWatchCore/`** — `SendLogWatchCore` SwiftPM package: watch
  pure logic (attempt detection, RPE model, Tindeq protocol, hands-free force
  control, queues, dates). Foundation-only by design so it tests on the host.
- **`ios/App/SendLogWatch Watch App/`** + **`ios/App/SendLogWatchWidgets/`** —
  the watch app and its complications/Smart-Stack widgets (watchOS 10+),
  consumed by the native project rather than duplicated.
- **`native-plugins/sendlog-health-core/`** — `SendLogHealthCore` SwiftPM
  package: readiness/ACWR math, the write policy, and the readiness-widget
  contract shared by the phone app and its widget.
- **`supabase/`** — `migrations/`, `tests/` (SQL regressions), `seed.sql`,
  `config.toml`. Migration tooling: `scripts/apply-migrations.mjs`,
  `scripts/migration-status.mjs`.
- **`mcp/`** — a **separate, package-local, read-only MCP server** (own
  `package.json` + lockfile + its own CI job). It is not part of the app and has
  no root npm wiring; all of its commands are `cd mcp`-scoped.
- **`scripts/`** — repo gates (anti-slop, static validation, coverage,
  generated-project assertion) and migration tooling. **`tools/anti-slop-swift/`**
  — vendored Swift lint tool. **`fastlane/`** — the `native_beta` TestFlight
  lane. **`docs/`** — runbooks and history (see below).

### Stale guidance warning

The web/Capacitor surface was retired in #857. Any instruction to run a root
`npm` script, a Vite/Capacitor sync, or the old Capacitor `App` scheme's
xcodeproj predates that cut and must not be followed. The full inventory of
what was removed, and which retained surface owns each concern, is
`docs/architecture/857-removal-inventory.md`. A bounded smoke check
(`scripts/check-docs-stale-commands.sh`) fails this file (and the other current
entrypoints) if a retired command name reappears — extend its explicit
historical allowlist only for files that document the removal on purpose.

## Commands

Run `just --list` first — the justfile mirrors what CI actually runs and is the
canonical gate entry point (`brew install just`). There is **no root npm
package**; `mcp/` keeps its own package-local commands.

| Recipe | What it actually covers |
|---|---|
| `just core` | PRIMARY gate: `swift test --package-path native/SendmeterNative` — the `SendmeterCore` + `SendmeterWeather` SwiftPM suites plus source-text wiring tests (~1136 tests). Host, no simulator. |
| `just watch-core` | `swift test --package-path ios/App/SendLogWatchCore` — watch pure logic. Host, no simulator. |
| `just health-core` | `swift test --package-path native-plugins/sendlog-health-core` — readiness/ACWR math + write policy. Host, no simulator. |
| `just slop` | `bash scripts/validate-anti-slop.sh` — anti-slop config/wrapper/CI-wiring structural check (fast, no compiler). |
| `just slop-cold` | Cold-build regression for the vendored anti-slop tool (cleans its build dir, rebuilds, requires the scanned-file signal). |
| `just check-static` | `bash scripts/validate-native-static.sh` — parses every native Swift file with `swiftc -parse` and checks XcodeGen project membership. No xcodebuild. |
| `just fast` | `slop` + the three SwiftPM suites — the fast lane after an edit. |
| `just gen` | `cd native/SendmeterNative && xcodegen generate` — regenerates `SendmeterNative.xcodeproj` from `project.yml`. Required before any xcodebuild. |
| `just check-watch-project` | `ruby scripts/assert-native-watch-project.rb` — generated-project ownership gate; run after any gen-affecting change. |
| `just build-ios` | Unsigned generic iOS Simulator Debug build of the native app (needs Xcode). |
| `just build-watch` | Unsigned generic watchOS Simulator Debug build of the watch app (needs Xcode). |
| `just ci` | Everything CI gates on, in CI order: `slop slop-cold core watch-core health-core gen check-watch-project build-ios build-watch` (excludes simulator-only test steps). |

`mcp/` commands (package-local, from `mcp/`): `cd mcp && npm ci` (or
`npm install`), then `cd mcp && npm run typecheck`, `cd mcp && npm test`,
`cd mcp && npm run build`, plus `npm run lint`, `npm run audit`, and
`npm run dry-run` — the last one runs the built server against a dry-run config
without touching a live service.

After any Swift or npm step, check `git status`: SPM resolution (including
`swift test`) has been observed rewriting
`native/SendmeterNative/Package.resolved` — revert that churn if you did not
intend it. Commit only intentional files.

## What proves what (verification ladder)

1. **Pure logic → SwiftPM tests (host, no simulator).** `just core`,
   `just watch-core`, `just health-core`. Put new logic in a pure package first
   (`Sources/Core`, `SendLogWatchCore`, `SendLogHealthCore`), UI wiring second.
   Focused run: `swift test --package-path native/SendmeterNative --filter <Class>`.
2. **App-target and widget code → xcodebuild.** `swift test` compiles only the
   `SendmeterCore` target (`Sources/Core` + `App/ChartTheme.swift`) and
   `SendmeterWeather`. Everything under `Sources/App`, `Sources/Data`,
   `Sources/Platform`, `Sources/Features`, `Sources/Shared`, `Sources/Widgets`
   is compiled by the Xcode app/widget targets only — **a green `just core`
   does not prove an app-target change compiles.** Run `just gen` first, then
   `just build-ios` (or `just build-watch`). Cheap pre-check for one app-target
   file: `xcrun swiftc -parse <file>` (syntax only; the Xcode build is the
   compile authority).
3. **App-target tests → simulator.** `Tests/SendmeterNativeTests` compiles
   against the application module (PostgREST/date/session recovery wiring,
   sheet presentation, structural haptics, routine visual wiring, guided side
   behavior, readiness widget). CI runs:
   `xcodebuild test -project native/SendmeterNative/SendmeterNative.xcodeproj -scheme SendmeterNative -destination "id=<sim UDID>" -only-testing:SendmeterNativeTests CODE_SIGNING_ALLOWED=NO`
4. **UI tests → simulator, local only.** `Tests/SendmeterNativeUITests`
   (menu activation) is in the `SendmeterNative` scheme's test action, but no
   workflow runs it — a UI-test claim is unverified unless you ran it.
5. **Watch tests.** The watch *pure* logic is `just watch-core`, also run in
   Linux CI (`ios-ci.yml` `package-tests`). The watch app-target suite in
   `ios/App/SendLogWatchTests/` has no target in `project.yml` and no workflow
   reference after #857 — **do not claim it ran.** If you need watch
   app-target coverage, wiring that suite into a target is its own issue.
6. **Device-only evidence — never claim it from a simulator or CI run:**
   HealthKit runtime + background delivery, real HRV/sleep data, Bluetooth
   (Tindeq), attempt detection from real motion, Live Activities on a signed
   build, complications/Smart Stack, passkeys, WatchConnectivity delivery
   between a real phone/watch pair, `BGAppRefreshTask` scheduling, and
   signing/provisioning. Flag these as device-only instead of implying
   verification.

## Environment and data boundaries

- **Native builds compile in the PRODUCTION Supabase project.** The phone
  (`native/SendmeterNative/Sources/Data/SupabaseService.swift`) and the watch
  (`ios/App/SendLogWatch Watch App/Resources/SupabaseConfig.plist`) hardcode
  `zznsqmcewtzlnfoiefkk.supabase.co`; a Debug device build reads and writes
  production data. Use a throwaway account for device-only checks — never the
  real account — and never run a destructive flow against it.
- **The local Supabase stack is for SQL regressions and MCP e2e verification
  only.** Start it with the Supabase CLI (`supabase start`), apply migrations
  with `supabase db reset --local --no-seed`, run a SQL suite with
  `supabase test db --local supabase/tests/<file>.sql` — that is exactly what
  `supabase-tests.yml` does. It never links to, resets, or queries a hosted
  project, and no app build points at it.
- **Two hosted projects on two accounts:** dev/preview
  `mjkndfhjnipomjjhgsxv`, prod `zznsqmcewtzlnfoiefkk`. One Management API token
  (`~/.supabase/access-token`) reaches both (Developer role suffices for the
  Management API). The dev project is free-tier and auto-pauses after ~7 idle
  days — unpause it before it must receive a push or before verifying a
  release.
- **The committed Supabase URL + publishable anon key are intentional source
  credentials** (RLS is the security boundary). They are matched byte-for-byte
  in `.gitleaks.toml`; do not rotate, replace, or "clean up" them in unrelated
  changes.
- **Migrations auto-apply on merge.** `deploy-migrations.yml` runs on any push
  touching `supabase/migrations/**`: `staging` → dev, `main` → prod. There is
  no required-reviewer gate on this plan, so **the merge is the human gate** —
  merging to `main` applies DDL to production.
- **Vercel is retained but is no longer a deploy target of this repo.** The web
  deploy workflow was removed in #857; the Vercel project, domain, and
  credentials are untouched. Do not change them from repo work — a future
  public site needs its own approved issue.
- **No production writes from a lane.** No live DB migration/configuration, no
  production data writes, no credential changes, no deployment/release work
  unless the task explicitly says so and the owner has approved it.

## Xcode build discipline

- **Never run two `xcodebuild` invocations concurrently** on this project —
  shared DerivedData / SPM checkouts corrupt each other ("couldn't be removed /
  File exists" resolve errors). Build serially; a failed resolve just needs a
  rerun.
- **One heavy Xcode build at a time on the host.** Other lanes serialize on
  this; do not start a build while another is running, and prefer the cheap
  gates (`just slop`, `just core`, `just check-static`) while iterating.
- `SendmeterNative.xcodeproj` is generated: run `just gen` before any
  xcodebuild, never commit or hand-edit the project file, and run
  `just check-watch-project` after any gen-affecting change.

## CI (what each workflow really covers)

`.github/workflows/` — the jobs that exist today:

| Workflow | Covers |
|---|---|
| `native-swift.yml` | `Core tests` — anti-slop structural + cold checks, advisory Swift lint, coverage helper self-test, then `scripts/swift-coverage.sh` over the three pure packages. `iOS Simulator build` — XcodeGen, generated watch-graph assertions, package resolve, boot a simulator, unsigned app build, then `-only-testing:SendmeterNativeTests`. Path-filtered to native/watch/health-core/anti-slop paths. |
| `ios-ci.yml` | `package-tests` — `SendLogWatchCore`'s SwiftPM suite in a Linux `swift:6.3` container (no simulator). `native` — macOS: XcodeGen, unsigned native iOS app build, unsigned watch app build. |
| `supabase-tests.yml` | `purge-sql` — disposable local stack (`supabase start`, `db reset --local --no-seed`), then `supabase test db` on `supabase/tests/purge_sync_generation.sql` and `supabase/tests/health_metrics_precedence.sql`, then `bash scripts/test-health-precedence-race.sh`. Never touches a hosted project. |
| `mcp.yml` | `quality` — `cd mcp`-scoped `npm ci`, `npm audit --audit-level=high`, typecheck, tests, build. |
| `secret-scan.yml` | `gitleaks` — pinned 8.30.1, allowlist self-test with disposable fixtures, then a full-tree `--no-git` scan (current files, not history). |
| `deploy-migrations.yml` | `apply` — by-name migration apply via `scripts/apply-migrations.mjs --target dev\|prod`, gated by the `Preview`/`Production` GitHub environments. |
| `native-testflight.yml` | `gate` + `native-beta` — dispatch-only signed Release build → TestFlight (`fastlane native_beta`). |
| `agent-*.yml` | Scheduled agent-ops workflows, disabled in the GitHub UI (verified 2026-09-18). Not part of product CI. |

## Supabase migrations (by NAME, never by version)

- `scripts/apply-migrations.mjs --target dev|prod` is the engine behind
  `deploy-migrations.yml`. It applies pending migrations **by name** via the
  Management API (access token only — no DB password, no `supabase link`, so
  `supabase/config.toml`'s hardcoded ref cannot misfire) and records name +
  version in `supabase_migrations.schema_migrations`. It is append-only: an
  unrecorded *older* migration fails the run — backfill the ledger row by hand,
  never re-run history.
- Version-based diffs are wrong here: prod's ledger carries apply-time versions
  from the MCP `apply_migration` era while local files carry file timestamps, so
  `supabase db push` would re-apply recorded history.
- Parity check: `node scripts/migration-status.mjs` prints the dev/prod table.
  The ledger only records what was *reported* applied — a green table means
  "nothing pending", not "schemas match".
- GitHub environments: `Preview` (dev, deployable from `staging`) and
  `Production` (prod, `main` only), plus lowercase `testflight`. Match that
  capitalisation exactly — GitHub silently *creates* a missing environment and
  the job then runs with no secrets. Keep `Preview` unrestricted: a
  deployment-branch policy there previously made PR-branch deployments fail
  with `startup_failure` (Vercel-era web integration, retired in #857).

## Release / TestFlight (human-only)

- TestFlight builds come from `main` only: the build uses the production
  Supabase project and only `main` carries the migration-verified schema. Flow:
  promote `staging` → `main`, wait for the Production migration run, then
  dispatch the native TestFlight workflow from `main`. Promoting to `main` and
  dispatching TestFlight are **owner actions** — agents do not do them.
- `gh workflow run "Native TestFlight" --ref main` — `workflow_dispatch` only
  (macOS runner minutes are the dominant CI cost, so there is no per-merge
  build). `fastlane native_beta` runs headless through the ASC API key in the
  `testflight` environment: it regenerates the project, registers/verifies App
  IDs and capabilities, fetches four distribution profiles (app, watch app,
  phone widget, watch widget), pins manual signing for those four targets at
  archive time, and injects the build number
  (`latest_testflight_build_number + 1`). **Never hand-bump
  `CURRENT_PROJECT_VERSION`.** Always `bundle exec` (Ruby is pinned in
  `.mise.toml` + `Gemfile.lock`) with `LANG=en_US.UTF-8`.
- Watch HealthKit/App-Group capabilities are a **manual Apple Developer portal
  prerequisite** the lane verifies but cannot enable.
- App Store copy lives in `docs/app-store-checklist.md` (native submission
  section) and `docs/app-review-notes.md` (reviewer notes).

## Non-obvious things that still bite

- **Dates must be Gregorian.** A Thai-region device defaults `Calendar.current`
  to the Buddhist calendar (year + 543), which once corrupted every stored date.
  Use the repo's Gregorian helpers (`DateSupport` in `SendmeterCore`,
  `SendLogWatchCore`, and `SendLogHealthCore`); a DB `check` constraint bounds
  dates as a backstop.
- **The watch never signs itself in.** The phone holds the session and relays a
  short-lived **access token only** (no refresh token anywhere native — the
  watch's `SupabaseClient` has an `accessToken` provider and no `AuthClient`).
  Don't reintroduce a watch-native login or a refresh-token holder: refresh
  tokens are single-use with reuse detection, so a second holder would revoke
  the whole session family.
- **A decision made from state captured in a closure that outlives the await it
  came from is this repo's most-repeated defect.** Inside any async path, read a
  ref/actor/current value — not a captured snapshot — and set any dedupe guard
  **before** the first `await`. Prefer extracting the logic into a pure package
  type and testing concurrent invocation directly.
- **`public` Swift types lose implicit `Sendable`.** Swift infers it for
  internal types but never for public ones, so moving a value type into a
  package silently drops the conformance. Declare it explicitly on public
  pure-data types.
- **A green SwiftPM run says nothing about the app target.** See the ladder
  above; the same trap applies to CI — check which job actually ran.
- **Anti-slop (`tools/anti-slop-swift`, pinned upstream revision):**
  `.anti-slop.json` disables exactly `no-any-dictionary-value` and
  `no-any-parameters` (WatchConnectivity's system API needs them); the rest
  stay enabled. CI's Swift lint step is advisory, but a missing path/config or
  a tool-build failure is a real failure. When a force unwrap, cast, `try`, or
  process-termination primitive is genuinely required, put a specific
  `// SAFETY:` explanation in the contiguous comment block above it.
- **Coverage floors** for the three pure packages (and the helper self-test)
  live in `docs/testing.md`; the floors are a small margin below measured
  baselines — don't round them up.

## Names (display vs. internal — keep the split)

- **User-facing name is "Sendmeter"** (App Store display name, in-app copy,
  widget display names).
- **Internal identifiers stay `sendlog`/`SendLog`** and should NOT be renamed:
  bundle IDs `com.jirathip.sendlog*`, Xcode target/scheme names
  (`SendLogWatch Watch App`), Swift package names (`SendLogWatchCore`,
  `SendLogHealthCore`), and Swift file/dir names.

## Working style here

- This is a solo project moving fast. Match the surrounding code's style.
- Branch off `staging` (not `main`); `main` is human-promoted only. Commit
  style: `#NNN native: ...` / `#NNN <area>: ...`.
- User-facing changes get a concise bullet under **Unreleased** in
  `RELEASE_NOTES.md`; internal-only work does not need an entry.
- Backlog lives in **GitHub Issues** on this repo (labels `type: *`,
  `area: *`, `priority: *`, plus `blocks-release`). Closed issues use
  `--reason completed` for shipped work and `--reason "not planned"` for
  dropped ideas — the space matters.
- Native/HealthKit/BLE behavior cannot be verified in the simulator — flag
  device-only work rather than claiming it verified.

## Historical notes

- **Web/Capacitor retirement (#857).** The React app, root npm package, Vite
  config, Capacitor iOS host project (and its old `App` scheme), and the four
  Capacitor plugin packages were removed.
  `docs/architecture/857-removal-inventory.md` is the ownership map that
  decided it (what was REMOVE vs KEEP, and why), plus the
  later #899 manual-Force removal addendum. Older docs that describe the
  retired web layer — `docs/error-monitoring.md` (web Sentry) — are kept for
  reference and are marked superseded at the top; do not follow them.
