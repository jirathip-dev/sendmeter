# Dependabot and CI fan-out policy

This policy reduces routine dependency-update fan-out without weakening audit,
secret scanning, or native correctness gates.

## Policy

`.github/dependabot.yml` sets `open-pull-requests-limit: 1` for every
version-update manifest: the root npm project, `mcp/`, GitHub Actions, and the
eight SwiftPM manifests. The weekly schedules are unchanged. Dependabot's
`security-updates` groups remain separate; the open-pull-requests limit applies
to version updates, so security updates retain their own path. Major updates
remain in separate groups and require manual triage rather than routine
handling.

## Path-aware CI review

The expensive native workflows already use workflow-level path filters, which
prevents a runner from being allocated for unrelated changes:

- `ios-ci.yml` runs for `ios/**`, the four Capacitor native plugin trees, or
  its own workflow file.
- `native-swift.yml` runs for the native Swift/watch trees, native health core,
  Swift tooling and its gate scripts, or its own workflow file.
- `ci.yml` remains unconditional for pull requests so npm audit, typecheck,
  lint, tests, and builds continue to cover every relevant web/dependency
  change.
- `secret-scan.yml` remains unconditional for pull requests and branch pushes;
  gitleaks must not be hidden by a dependency path filter.
- `supabase-tests.yml` remains limited to migration/test/package/workflow
  changes, and the migration deploy stays limited to migration/deploy-script
  changes. `deploy-web.yml` remains merge-triggered and is not a pull-request
  fan-out source.

Therefore an unrelated root dependency-only change keeps the web, audit, and
secret gates but skips the native/iOS jobs; a change under the Swift/iOS or
Capacitor plugin paths keeps the native gates.

## Before / after measurement

The issue recorded the before baseline as **10 update PRs**, **29 workflow
runs**, and **48.37 minutes wall-clock**. The runners were Blacksmith runners;
GitHub-billable minutes were recorded as **0**.

After the policy, routine version updates have at most one open PR per
manifest per weekly cycle:

```
2 npm manifests + 1 GitHub Actions manifest + 8 SwiftPM manifests = 11
routine update PR slots
```

This is a queue bound, not a promise that every manifest receives an update.
Security updates are intentionally excluded from the routine bound. Native
runner allocation is further reduced by the existing path filters: unrelated
dependency changes use the Blacksmith 4-vCPU Ubuntu quality/audit and
secret-scan jobs, while only Swift/iOS-affecting paths allocate the Blacksmith
6-vCPU macOS native jobs. The exact after wall-clock and hosted workflow-run
count require the next Dependabot weekly cycle; Blacksmith accounting and the
zero GitHub-billable-minute result must be confirmed from that hosted run.

## Fixture evidence

The policy's trigger matrix is:

| Fixture change | Expected relevant gates | Local proof | Hosted proof |
| --- | --- | --- | --- |
| Security/audit-style dependency change | `CI` audit and `Secret scan` | YAML inspection confirms both workflows have no dependency path filter | Required on the PR: GitHub event admission and successful jobs |
| Swift/iOS-affecting dependency change under `ios/**`, native Swift, or Capacitor plugin paths | `Native Swift` and/or `iOS CI`, plus `CI` and `Secret scan` | YAML path-list inspection confirms the matching paths | Required on the PR: GitHub path-filter admission and successful native jobs |
| Unrelated dependency-only change outside those paths | `CI` and `Secret scan`; native/iOS jobs skipped | YAML path-list inspection confirms no matching native path | Required on the PR: GitHub skipped-state confirmation for native/iOS workflows |

These local checks validate the committed trigger contract; they cannot emulate
GitHub's hosted path-filter event evaluation. The orchestrator must attach the
hosted run links and final skipped/successful conclusions to the PR evidence.
