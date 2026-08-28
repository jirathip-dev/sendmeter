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

The expensive native workflows use a workflow-level path filter plus a cheap
dependency classifier, which prevents a macOS runner from being allocated for
unrelated changes:

- `ios-ci.yml` admits `ios/**`, the four Capacitor native plugin trees, its own
  workflow file, and the root npm manifests to a Blacksmith Ubuntu classifier.
  The classifier compares root dependency declarations and lockfile changes
  for Capacitor/plugin families and BLE/Health-related packages. Only a
  native-facing result promotes the macOS `swift` job; unrelated root npm
  changes run the cheap package-test/classifier work but skip macOS.
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
secret gates and skips the macOS native/iOS job; a native-facing root package
or lockfile change, or a change under the Swift/iOS or Capacitor plugin paths,
keeps the native gates.

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
runner allocation is further reduced by the classifier: unrelated dependency
changes use the Blacksmith 4-vCPU Ubuntu classifier plus quality/audit and
secret-scan jobs, while only Swift/iOS-affecting paths allocate the Blacksmith
6-vCPU macOS native jobs. The exact after wall-clock and hosted workflow-run
count require the next Dependabot weekly cycle; Blacksmith accounting and the
zero GitHub-billable-minute result must be confirmed from that hosted run.

Because major groups also consume the one version-update slot, operators must
close stale major PRs promptly when they are not being actively upgraded.
Otherwise a stale major can starve routine patch/minor updates for that
manifest. Root npm major PR #827 and native GRDB major PR #829 are the current
instances requiring this manual treatment.

## Fixture evidence

The policy's trigger matrix is:

| Fixture change | Expected relevant gates | Local proof | Hosted proof |
| --- | --- | --- | --- |
| Security/audit-style dependency change | `CI` audit and `Secret scan` | Workflow trigger inspection proves both are unfiltered; the gate result is not simulated locally | Required on the PR: a real high/critical audit fixture must fail the audit gate, while gitleaks still scans |
| Swift/iOS-affecting dependency change under `ios/**`, native Swift, Capacitor plugin paths, or native-facing root packages | `Native Swift` and/or `iOS CI`, plus `CI` and `Secret scan` | Classifier source inspection proves the selected package families and native paths promote the macOS job | Required on the PR: a real positive dependency fixture must admit and pass the native gate |
| Unrelated dependency-only change outside those paths | `CI` and `Secret scan`; macOS native/iOS job skipped | Classifier source inspection proves unrelated root packages return false | Required on the PR: GitHub must show classifier success and no macOS native job |

These local checks validate the committed trigger and classifier contract; they
cannot emulate GitHub's hosted path-filter event evaluation, Dependabot's
queue behavior, or an audit failure. The orchestrator must attach hosted links
for the positive native fixture and intentionally failing audit fixture; the
current PR itself only proves the unrelated-change skip path.
