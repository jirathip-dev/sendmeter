# Dependabot and CI fan-out policy

This policy reduces routine dependency-update fan-out without weakening audit,
secret scanning, or native correctness gates.

## Policy

`.github/dependabot.yml` sets `open-pull-requests-limit: 1` for each retained
version-update manifest: `mcp/`, GitHub Actions, and the retained SwiftPM
manifests. The retired root web/Capacitor manifest is gone. The weekly schedules are unchanged. Dependabot's
`security-updates` groups remain separate; the open-pull-requests limit applies
to version updates, so security updates retain their own path. Major updates
remain in separate groups and require manual triage rather than routine
handling.

## Path-aware CI review

The expensive native workflows use a workflow-level path filter plus a cheap
dependency classifier, which prevents a macOS runner from being allocated for
unrelated changes:

- `ios-ci.yml` is scoped to the generated native project, retained Watch
  sources, health core, and native gate scripts; it has no root npm classifier.
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

After policy — **expected maximum, measured values to be recorded after the
first policy cycle (next scheduled 2026-08-31)** — is one open routine
version-update PR per manifest:

```
mcp npm 1 + GitHub Actions 1 + 4 surviving SwiftPM manifests = 6 PRs
maximum routine version-update fan-out per weekly cycle
```

This is a queue bound, not a promise that every manifest receives an update.
Security updates are intentionally excluded from the routine bound. The
classifier further limits expensive native allocation: unrelated dependency
changes use the Blacksmith 4-vCPU Ubuntu classifier plus quality/audit and
secret-scan jobs, while native-facing changes can allocate the Blacksmith
6-vCPU macOS native job. The measured after workflow-run count, wall-clock,
Blacksmith accounting, and GitHub-billable minutes remain pending until that
first policy cycle; the before baseline recorded 0 GitHub-billable minutes.

Because major groups also consume the one version-update slot, operators must
close stale major PRs promptly when they are not being actively upgraded.
Otherwise a stale major can starve routine patch/minor updates for that
manifest. Root npm major PR #827 is the current instance requiring this
manual treatment; #829 was merged and is no longer a stale-major example.

## Fixture evidence

The policy's trigger matrix is:

| Fixture change | Expected relevant gates | Local proof | Hosted proof |
| --- | --- | --- | --- |
| Security/audit-style dependency change | `CI` audit and `Secret scan` | Workflow trigger inspection proves both are unfiltered; the gate result is not simulated locally | Hosted audit fixture failed quality at [run 33158879834](https://github.com/jirathip-dev/sendmeter/actions/runs/33158879834), proving the high-severity audit gate bites |
| Swift/iOS-affecting root dependency change | `Native Swift`/`iOS CI`, plus `CI` and `Secret scan` | Classifier tests cover Capacitor scopes, safe-area, and lockfile-only changes | Hosted `@capacitor-community/safe-area` fixture classified and ran Swift successfully at [run 33160303844](https://github.com/jirathip-dev/sendmeter/actions/runs/33160303844) |
| Unrelated root dependency-only change | `CI` and `Secret scan`; macOS native/iOS job skipped | Classifier tests cover unrelated packages | Hosted `@types/node` fixture classified false and skipped Swift at [run 33160110906](https://github.com/jirathip-dev/sendmeter/actions/runs/33160110906) |

The three hosted fixtures above were appended as temporary commits and then
reverted without force-pushing: unrelated fixture `19990be` → revert `1a77b08`,
native fixture `2b76a18` → revert `a16a39b`, and audit fixture `a7c9455` →
revert `0cd24b1`. The current branch retains the run links while its net
product/configuration diff restores the intended tree. Local checks cannot
emulate GitHub's hosted path-filter event evaluation or Dependabot queue
behavior.
