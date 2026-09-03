# Dependabot and CI fan-out policy

This policy reduces routine dependency-update fan-out without weakening audit,
secret scanning, or native correctness gates.

## Policy

`.github/dependabot.yml` sets `open-pull-requests-limit: 1` for each of the 7
retained version-update manifests: `mcp/`, GitHub Actions, four retained SwiftPM
manifests, and Bundler. The retired root web/Capacitor manifest is gone. The weekly schedules are unchanged. Dependabot's
`security-updates` groups remain separate; the open-pull-requests limit applies
to version updates, so security updates retain their own path. Major updates
remain in separate groups and require manual triage rather than routine
handling.

## Path-aware CI review

The expensive native workflows use a workflow-level path filter plus a cheap
dependency classifier, which prevents a macOS runner from being allocated for
unrelated changes:

- `ios-ci.yml` is scoped to the generated native project, retained Watch
  sources, health core, and native gate scripts; path classification prevents
  unrelated changes from allocating a macOS runner.
- `native-swift.yml` runs for the native Swift/watch trees, native health core,
  Swift tooling and its gate scripts, or its own workflow file.
- `mcp.yml` is scoped to the retained MCP package and its package-local npm gates.
- `secret-scan.yml` remains unconditional for pull requests and branch pushes;
  gitleaks must not be hidden by a dependency path filter.
- `supabase-tests.yml` remains limited to migration/test/package/workflow
  changes, and the migration deploy stays limited to migration/deploy-script
- The retired `deploy-web.yml` is removed; Vercel resources remain untouched.

Therefore an unrelated MCP dependency-only change keeps the MCP, audit, and
secret gates and skips the macOS native/iOS job; a native-facing change under
retained Swift/iOS paths keeps the native gates.

## Before / after measurement

The issue recorded the before baseline as **10 update PRs**, **29 workflow
runs**, and **48.37 minutes wall-clock**. The runners were Blacksmith runners;
GitHub-billable minutes were recorded as **0**.

After policy — measured after the first post-policy cycle. Measurement window:
2026-08-30T19:00Z → 2026-09-02T02:00Z (covers both the config-true
Asia/Bangkok schedule readings and the alternate UTC reading; recorded
2026-09-03):

| Metric | Before baseline | After (measured first cycle) |
| --- | --- | --- |
| Routine version-update PRs | 10 | 1 — #877 only (mcp npm development group, @types/node 26.3.0 → 26.4.0, opened 2026-08-30T20:23:09Z) |
| Workflow runs on dependabot branches | 29 | 2, both success |
| Wall-clock runner time | 48.37 min | ~0.7 min (42 s total: Secret scan run [33333499451](https://github.com/jirathip-dev/sendmeter/actions/runs/33333499451) = 20 s, MCP run [33333499471](https://github.com/jirathip-dev/sendmeter/actions/runs/33333499471) = 22 s) |
| Runner class | Blacksmith | Blacksmith 4-vCPU Ubuntu (`blacksmith-4vcpu-ubuntu-2404`); no macOS native job allocated for the MCP-only change |
| GitHub-billable minutes | 0 | 0 (timing API reports 0 ms billable; Blacksmith-side charge stays separate, as before) |

The single in-window PR ran only its relevant gates — `quality` (MCP) and
`Secret scan` (gitleaks) — and skipped the macOS native/iOS job, so the
path-aware classifier worked as designed for the MCP-only change. Coverage is
unchanged: the native-affecting and unrelated fixtures in the "Fixture
evidence" section below remain the proof that Swift/iOS-affecting dependency
changes still run their native gates while unrelated changes skip them.
GitHub Actions, SwiftPM (all four retained manifests), and Bundler routine
slots produced **0 PRs** in the window (no updates available in that cycle).

Security updates kept their separate live path: #884 (mcp-npm-security,
fast-uri 3.1.5 → 3.1.7) opened 2026-09-03T02:52Z with Secret scan and MCP runs
green — outside the measured routine window and exempt from the routine queue
bound, recorded to show the security path still flows.

This remains a queue bound, not a promise that every manifest receives an
update each cycle: mcp npm 1 + GitHub Actions 1 + 4 surviving SwiftPM
manifests + Bundler 1 = 7 routine version-update PRs maximum per weekly cycle,
with security updates excluded from the bound.

Because major groups also consume the one version-update slot, operators must
close stale major PRs promptly when they are not being actively upgraded.
Otherwise a stale major can starve routine patch/minor updates for that
manifest. Operators should apply this treatment to any retained manifest.

## Fixture evidence

The policy's trigger matrix is:

| Fixture change | Expected relevant gates | Local proof | Hosted proof |
| --- | --- | --- | --- |
| Security/audit-style dependency change | `CI` audit and `Secret scan` | Workflow trigger inspection proves both are unfiltered; the gate result is not simulated locally | Hosted audit fixture failed quality at [run 33158879834](https://github.com/jirathip-dev/sendmeter/actions/runs/33158879834), proving the high-severity audit gate bites |
| Swift/iOS-affecting root dependency change | Native Swift/iOS CI, plus CI and Secret scan | Classifier tests cover Capacitor scopes, safe-area, and lockfile-only changes | Hosted @capacitor-community/safe-area fixture classified and ran Swift successfully at [run 33160303844](https://github.com/jirathip-dev/sendmeter/actions/runs/33160303844) |
| Unrelated root dependency-only change | CI and Secret scan; macOS native/iOS job skipped | Classifier tests cover unrelated packages | Hosted @types/node fixture classified false and skipped Swift at [run 33160110906](https://github.com/jirathip-dev/sendmeter/actions/runs/33160110906) |

The three hosted fixtures above were appended as temporary commits and then
reverted without force-pushing: unrelated fixture `19990be` → revert `1a77b08`,
native fixture `2b76a18` → revert `a16a39b`, and audit fixture `a7c9455` →
revert `0cd24b1`. The current branch retains the run links while its net
product/configuration diff restores the intended tree. Local checks cannot
emulate GitHub's hosted path-filter event evaluation or Dependabot queue
behavior.
