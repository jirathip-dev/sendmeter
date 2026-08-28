# Dependency security and maintenance

This repository is configured for Dependabot version updates. Native Dependabot
security updates are currently inert: a read-only settings check found
vulnerability alerts unavailable and automated security fixes disabled. The
human gate is Guy-only: under repository Settings → Advanced Security, Guy must
enable the dependency graph, Dependabot alerts, and Dependabot security
updates. GitHub requires those features for grouped security updates. Issue
#804 remains open until Guy explicitly approves that settings change. Until
then, the `security-updates` groups in `.github/dependabot.yml` cannot produce
native security PRs; the CI `npm audit` gates and version-update PRs remain
active.

All updates are reviewable pull requests only: there is no auto-merge
configuration, and dependency updates do not receive write permissions beyond
the normal Dependabot workflow. A maintainer reviews the generated diff, the
relevant CI gates, and any lockfile changes before merging.

## Dependabot policy

The choice here is Dependabot rather than Renovate. Corral issue #212 defers
that mechanism choice to Sendmeter; it is not evidence of an independent
Corral selection. Once this Sendmeter standard lands, Corral should adopt
Dependabot for the same cross-repo operator model. GitHub's current
[Dependabot options reference](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference#package-ecosystem)
lists npm, GitHub Actions, and Swift (v5 and v6) as supported ecosystems.

`.github/dependabot.yml` monitors:

- the root npm project and the separate `mcp/` npm project each week;
- every GitHub Actions workflow each week; and
- the SwiftPM manifests in `ios/App/SendLogWatchCore`,
  `native-plugins/sendlog-{auth-bridge,health-core,health,live-activity,passkey}`,
  `native/SendmeterNative`, and `tools/anti-slop-swift` each week.

Production and development npm patch/minor updates are grouped separately;
major updates are grouped separately for deliberate manual triage. Security
updates are grouped per ecosystem and retain their own unthrottled path. Swift
updates use the same patch/minor versus major split. Each manifest has one open
version-update slot, while security updates are not subject to that limit.

The repository default branch is `staging`, so Dependabot targets `staging`.
The config intentionally leaves out `target-branch`: GitHub documents that a
non-default target makes the normal Dependabot options stop applying to
security updates, while security fixes must continue to use the default branch
and the security grouping rules.

The generated `ios/App/CapApp-SPM/Package.swift` is owned by Capacitor and is
not a Dependabot manifest. The Xcode project's standalone
`ios/App/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
also has no `Package.swift` directory that Dependabot can own. Those generated
or project-level pins remain reviewable in native CI and must not be replaced
by a generic updater. Keep the native GRDB dependency coherent across
`project.yml`, `Package.swift`, and `Package.resolved`: the first two must
require the same exact version, and the lockfile must resolve that version to
its corresponding revision.

The four Capacitor plugin directories are included in the expensive
`.github/workflows/ios-ci.yml` path filter. A change under
`native-plugins/sendlog-auth-bridge`, `native-plugins/sendlog-health`,
`native-plugins/sendlog-live-activity`, or `native-plugins/sendlog-passkey`
therefore runs the macOS lane, which performs `npm ci`, `npx cap sync ios`, and
a phone `xcodebuild` compile that resolves and builds the generated
`CapApp-SPM` dependency graph; it is not covered by web CI alone.

## npm audit gate

The root and `mcp/` projects both expose the same explicit gate:

```sh
npm run audit
# equivalent to: npm audit --audit-level=high
```

CI runs that command immediately after each project's `npm ci`. A high or
critical advisory fails the job; informational, low, and moderate findings do
not silently change the threshold. There are no advisory exceptions in this
branch. If an upstream-only exception ever becomes unavoidable, it must name
the exact package and advisory, state why no compatible fix exists, include an
expiry/review date, and include a regression test; weakening the repository-wide
threshold is not an acceptable workaround.

Audit baseline captured on 2026-08-25 with the checked-in root lockfile:

| Project | Before | After the lockfile-only remediation |
| --- | --- | --- |
| root | 6 high, 0 critical (`brace-expansion`, `fast-uri`, `nanoid`, `postcss`, `tar`, `vite`) | 0 vulnerabilities |
| `mcp/` | 0 vulnerabilities | 0 vulnerabilities |

The root fix was `npm audit fix --package-lock-only`. It changed only the root
`package-lock.json`; the direct dependency ranges and the patched
`@capacitor-community/apple-sign-in` contract stayed intact. `npm ci` after the
change must still run `postinstall` and apply
`patches/@capacitor-community+apple-sign-in+7.1.0.patch`.

The same lockfile-only remediation also materially refreshed the build-tool
chain: Vite `8.0.14` → `8.2.2`, Rolldown `1.0.2` → `1.2.5`, and
`@oxc-project/types` `0.132.0` → `0.146.0`. The vulnerable transitive packages
were refreshed within compatible ranges (`brace-expansion`, `fast-uri`,
`nanoid`, `postcss`, and `tar`) rather than by changing direct dependency
ranges.

## Immutable CI inputs

Third-party GitHub Actions are referenced by commit SHA with the release tag in
a comment so Dependabot can propose intentional pin updates. The Swift Linux
container is pinned by image digest. XcodeGen is downloaded from its exact
2.46.0 release and checked against a committed SHA-256 before use. The Vercel
CLI is invoked at the exact npm version `56.5.0`, never a moving major tag.

When changing a pin, update the human-readable version comment, verify the new
commit or artifact digest from the upstream release, and run actionlint plus the
affected workflow checks. Do not replace a SHA with a mutable tag for
convenience.

## Operator response

1. Do not enable or disable repository security settings from an agent. Keep
   issue #804 open until Guy approves the Settings → Advanced Security gate
   for the dependency graph, Dependabot alerts, and Dependabot security
   updates.
2. Treat a high/critical `npm run audit` failure or Dependabot security PR as a
   blocking security change.
3. Reproduce with `npm ci && npm run audit` in the affected project, inspect the
   dependency path with `npm explain <package>`, and prefer a compatible
   lockfile or direct-range fix.
4. Run the normal web gates and any affected SwiftPM/native tests. Preserve every
   `Package.resolved` unless the pin update is deliberate, reviewed, and part
   of the same change.
5. Review Dependabot's permissions and diff; never enable auto-merge or grant
   dependency-update workflows write access as a shortcut.
6. If the only available upstream fix is incompatible, document the exact
   advisory and temporary exception in this file with an owner and expiry, add
   the regression coverage, and schedule removal before merging.
