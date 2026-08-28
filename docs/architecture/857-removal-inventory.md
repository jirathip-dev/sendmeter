# #857 legacy web/Capacitor removal inventory

Status: dependency/ownership map captured before deletion on `origin/staging`
`fe1a6de2d5b574ca7e36b0e53429131e82dc152c`.

## Baseline evidence

`git ls-files '*.ts' '*.tsx'` on this branch reports 406 tracked files:
`src/` 373, `mcp/` 18, and 15 scripts/config files. The retired product is
therefore the 373-file `src/` tree; `mcp/` is a separate package and is not a
web-app dependency. `native/SendmeterNative` is present at the staging head,
and its SwiftPM tests and native workflows do not require root npm.

## Native and Watch ownership proof (captured before deletion)

The pure-Swift XcodeGen spec is `native/SendmeterNative/project.yml`. Its
`packages` and target sources explicitly consume:

- `native/SendmeterNative/Sources/App`, `Sources/Data`, `Sources/Platform`,
  `Sources/Features`, `Sources/Shared`, and `Resources/*` for the phone app;
- `../../ios/App/SendLogWatchCore` as the `SendLogWatchCore` package;
- `../../native-plugins/sendlog-health-core` as the dependency-free
  `SendLogHealthCore` package and the widget's
  `ReadinessWidgetContract.swift` source;
- `../../ios/App/SendLogWatch Watch App` plus its `Assets.xcassets`, privacy
  manifest, and `Resources/SupabaseConfig.plist` for the Watch app;
- `../../ios/App/SendLogWatchWidgets` plus its privacy manifest for the Watch
  widget extension.

The same file declares the phone-to-watch dependency, Watch widget dependency,
and all native Swift package links. `grep -RIn` before deletion found no
imports or project.yml source entries for the legacy React `src/` tree, the
Capacitor phone host, or the four Capacitor plugin packages in the native
project. Conversely, `native/SendmeterNative/Package.swift` directly consumes
`ios/App/SendLogWatchCore` and `native-plugins/sendlog-health-core`.
Therefore the retained Watch directories and health-core package are KEEP;
the old phone host and Capacitor-only plugin bindings are REMOVE.

## Candidate paths and decisions

| Surface | Decision | Evidence / retained owner |
|---|---|---|
| `src/**` React/Vite/PWA app | REMOVE | No references from `native/SendmeterNative/project.yml`, `Package.swift`, or retained Swift sources; only root Vite/Capacitor scripts and web tests consume it. Native app sources are separate. |
| `ios/App/App/**` and `ios/App/App.xcodeproj/**` | REMOVE | `project.yml` does not consume them; its phone target is `native/SendmeterNative`. The old host imports Capacitor and embeds the web bundle. |
| `ios/App/CapApp-SPM/**`, `ios/App/ScreenshotTests/**`, `ios/App/SendmeterWidgets/**` | REMOVE | Generated/Capacitor phone artifacts and old web/widget screenshot targets; no source entry in the pure-Swift project. |
| `ios/App/SendLogWatchCore/**` | KEEP | Explicit SwiftPM dependency in `project.yml` and `Package.swift`; Watch package tests remain the pure Watch logic gate. |
| `ios/App/SendLogWatch Watch App/**`, its plist | KEEP | Explicit Watch application source/resource entries in `project.yml`. |
| `ios/App/SendLogWatchWidgets/**`, its plist | KEEP | Explicit Watch extension source/resource entries in `project.yml`. |
| `native/SendmeterNative/**` | KEEP | Pure-Swift phone app, widgets, packages, and tests are the shipped product and native CI source. |
| `native-plugins/sendlog-health-core/**` | KEEP | Explicit package dependency in both native `Package.swift` and `project.yml`; no Capacitor dependency. |
| `native-plugins/sendlog-auth-bridge/**`, `sendlog-health/**`, `sendlog-live-activity/**`, `sendlog-passkey/**` | REMOVE | Their Swift/plugin sources import Capacitor and are only resolved from the old `CapApp-SPM`/root package; no native project source entry consumes them. |
| root `package.json`, `package-lock.json` | REMOVE | Root package exists for retired web/Capacitor tooling. MCP has its own package and lockfile; migration deploy is dependency-free Node 18+ and SQL workflow installs no root package. |
| `tsconfig.json`, `vite.config.ts`, `eslint.config.js`, `capacitor.config.ts`, `vercel.json`, root web public/assets | REMOVE | Web/PWA/Vite/Capacitor/Vercel deployment boundary; no retained native or MCP consumer. `public/.well-known/apple-app-site-association` is part of the retired web host. |
| `scripts/verify-production-artifacts.mjs`, `verify-pwa-chrome.mjs` | REMOVE | Verify retired `ios/App/App/public` and PWA output. |
| `scripts/dev-local.sh`, `generate-icons.mjs`, `icon.svg`, `add_*_target.rb`, `swift-gate.sh`, screenshot helpers | REMOVE | Web/Capacitor/screenshot host tooling; no retained workflow consumer after CI reshape. |
| `scripts/apply-migrations.mjs`, `migration-safety.mjs`, `migration-status.mjs` | KEEP | `deploy-migrations.yml` invokes `apply-migrations.mjs`; the migration scripts use built-in Node APIs and remain operational tooling. |
| `supabase/**` migrations/tests and `scripts/test-health-precedence-race.sh` | KEEP | SQL workflow and migration verification remain required; paths and invocations are updated to run without root npm. |
| `native-swift.yml`, `native-testflight.yml`, `secret-scan.yml`, migration workflow | KEEP | Native Swift, pure Swift/Ruby/Xcode, gitleaks, and SQL responsibilities remain. |
| `ci.yml` | REMOVE | Root web quality job is retired; MCP gates move to dedicated `mcp.yml`. |
| `ios-ci.yml` | KEEP/RESHAPE | Retain Watch package tests and native iOS project generation/build; remove old Capacitor classifier, npm install, cap sync, and old App host build. |
| `deploy-web.yml` | REMOVE | Retires authenticated Vercel deployment wiring. Vercel project/domain/credentials retained untouched; future public site requires separate approved design/content issue. |
| `fastlane/Fastfile` native lane | KEEP/RESHAPE | Native TestFlight automation remains; legacy web/Capacitor beta and screenshot lanes are removed. |
| `RELEASE_NOTES.md` | SKIP | Internal architecture cleanup; shipped native product behavior is unchanged. |

MCP's five former shared TypeScript inputs (`metrics.ts`, `dates.ts`,
`force-curve.ts`, `capabilityModel.ts`, and `types.ts`) were moved under
`mcp/src/shared/` because `mcp/tsconfig.json` and `mcp/test/load.test.ts`
consume them. This is an explicit MCP-owned retained surface, not the retired
React app.

MCP gates run from `mcp/` with its package-local lockfile: `npm ci`, audit,
typecheck, test, and build. Native logic remains `swift test` in
`native/SendmeterNative` and `ios/App/SendLogWatchCore`; XcodeGen generates the
native phone/Watch project from `project.yml`. Migration deployment uses
Node's built-in fetch without npm installation. Secret scanning and native
TestFlight remain independent of Node.

The Vercel project/domain is retained untouched; future public site requires
separate approved design/content issue.

## After-state and measurable CI boundary

After deletion, `git ls-files '*.ts' '*.tsx'` reports 23 tracked files: 23 in
`mcp/` and zero in the retired root web tree. The five shared inputs listed
above are included in that MCP total. The measured TypeScript reduction is
therefore 406 → 23 files (373 root web files removed, with the five shared
inputs relocated rather than lost).

The baseline workflows contained 5 semantically parsed `npm ci` invocations
across 5 jobs. The after-state contains 1 `npm ci` invocation in 1 job:
MCP's package-local job in `mcp.yml`; native Swift/TestFlight, secret scanning,
Supabase CLI SQL verification, and migration deployment do not install the
retired root package. Workflow job count is reduced from 15 named workflow
jobs in the full baseline workflow set (`ci.yml`, `ios-ci.yml`,
`supabase-tests.yml`, `deploy-web.yml`, `testflight.yml`,
`native-swift.yml`, `native-testflight.yml`, `secret-scan.yml`, and
`deploy-migrations.yml`) to 10 named jobs in
the retained set (`mcp.yml`, `ios-ci.yml`, `supabase-tests.yml`,
`native-swift.yml`, `native-testflight.yml`, `secret-scan.yml`, and
`deploy-migrations.yml`). The old CI runtimes were not stable hosted metrics;
the recorded baseline fan-out was 29 workflow runs / 48.37 wall-clock minutes
from `docs/ci/dependabot-fanout.md`, while the after-state is path-filtered and
its hosted runtime is measured by GitHub on each exact PR SHA.

The concrete removed dependency inventory is the root `package.json` and
`package-lock.json` dependency graph, including React/Vite/PWA packages,
`@capacitor/core`, `@capacitor/cli`, `@capacitor/ios`,
`@capacitor-community/apple-sign-in`, `@capacitor-community/bluetooth-le`,
`@capacitor-community/keep-awake`, `@capacitor/app`,
`@capacitor/geolocation`, `@capacitor/haptics`, and
`@capacitor/preferences`, plus the local `file:` packages
`sendlog-auth-bridge`, `sendlog-health`, `sendlog-live-activity`, and
`sendlog-passkey`. The MCP package retains its own `package.json`, lockfile,
and dependency graph; native Swift packages retain their explicit SwiftPM
dependencies.
