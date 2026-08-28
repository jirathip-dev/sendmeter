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
