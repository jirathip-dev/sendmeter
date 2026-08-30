# Dependency security and maintenance

This repository is configured for Dependabot version updates. The dependency
graph, Dependabot alerts, and Dependabot security updates are enabled, authorized
by Guy on 2026-08-30 through the GitHub API, with live read-back verification.
GitHub requires those features for grouped security updates, so the
`security-updates` groups in `.github/dependabot.yml` can now produce native
security PRs; the CI `npm audit` gates and version-update PRs remain active.
This document previously recorded these settings as Guy-only and the gate as
unlifted; explicit owner authorization lifted that gate on 2026-08-30.

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

- the separate `mcp/` npm project each week;
- every GitHub Actions workflow each week; and
- the retained SwiftPM manifests in `ios/App/SendLogWatchCore`,
  `native-plugins/sendlog-health-core`, `native/SendmeterNative`, and
  `tools/anti-slop-swift` each week.

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

The generated native project is owned by `native/SendmeterNative/project.yml`.
Its generated Xcode project is not a Dependabot manifest. Keep the native GRDB
dependency coherent across
`project.yml`, `Package.swift`, and `Package.resolved`: the first two must
require the same exact version, and the lockfile must resolve that version to
its corresponding revision.

The retained native paths are included in `.github/workflows/ios-ci.yml`, which
generates `native/SendmeterNative/SendmeterNative.xcodeproj` and builds the
native phone and Watch graph. The retired Capacitor plugin directories and
CapApp-SPM graph are no longer part of the repository.

## npm audit gate

The retained `mcp/` project exposes the explicit gate:

```sh
cd mcp && npm audit --audit-level=high
```

CI runs that command immediately after MCP's package-local `npm ci`. A high or
critical advisory fails the job; informational, low, and moderate findings do
not silently change the threshold. There are no advisory exceptions in this
branch. If an upstream-only exception ever becomes unavoidable, it must name
the exact package and advisory, state why no compatible fix exists, include an
expiry/review date, and include a regression test; weakening the repository-wide
threshold is not an acceptable workaround.

The retained audit surfaces are `mcp/` and Bundler. MCP runs
`npm audit --audit-level=high` after its package-local `npm ci`; native release
automation runs through Bundler and `bundle exec fastlane native_beta`.

The retired root npm lockfile, Capacitor packages, and Capacitor patch are no
longer part of this repository and have no remediation workflow here. The
retained native Swift dependency pins are reviewed through native CI and the
retained SwiftPM Dependabot entries.

## Immutable CI inputs

Third-party GitHub Actions are referenced by commit SHA with the release tag in
a comment so Dependabot can propose intentional pin updates. The Swift Linux
container is pinned by image digest. XcodeGen is downloaded from its exact
2.46.0 release and checked against a committed SHA-256 before use. Retained
release tooling is invoked through the pinned Bundler/Fastlane dependencies.

When changing a pin, update the human-readable version comment, verify the new
commit or artifact digest from the upstream release, and run actionlint plus the
affected workflow checks. Do not replace a SHA with a mutable tag for
convenience.

## Operator response

1. Repository security settings remain owner-authorization-gated by policy:
   agents must not enable or disable them without explicit owner direction. The
   2026-08-30 authorization completed the enablement; issue #804 records the
   evidence.
2. Treat a high/critical MCP audit failure or Dependabot security PR as a
   blocking security change.
3. Reproduce with the affected package's install and audit gate, inspect the
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
7. Close stale major Dependabot PRs promptly when they are not being actively
   upgraded, because a major is still a version update and consumes the
   manifest's one-slot queue. Root npm #827 is the current open example;
   #829 was merged and is no longer stale. Leaving #827 stale can starve
   routine patch/minor updates.
