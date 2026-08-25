# Security checks

## Secret scanning

`.github/workflows/secret-scan.yml` runs on every pull request and on pushes to
`main` or `staging`. It uses the repository's standard
`blacksmith-4vcpu-ubuntu-2404` Linux runner, which is available for the
repository's existing CI jobs. It installs gitleaks 8.30.1 from the versioned
release archive, checks the archive's SHA-256 digest, runs a disposable-fixture
self-test, and then scans the checked-out tree with
`--no-git`. The gate deliberately checks current files rather than replaying
repository history; a credential that is found in a working tree must still be
removed and rotated, even if it was committed in the past. The CI checkout
contains tracked files only. The direct local command below is intentionally
broader: `--no-git` also scans ignored developer files, so it may find a local
`.env`; `--redact` keeps its value out of the output.
The CI scan also uses redacted verbose output, so a finding includes its rule,
file, line, and fingerprint without exposing the value.

Run a broader local working-tree check with gitleaks installed:

```sh
gitleaks detect --source . --no-git --config .gitleaks.toml \
  --redact --verbose --no-color --no-banner --exit-code=1
```

The committed `.gitleaks.toml` contains only narrow, documented exceptions for
the two native files' three current Supabase publishable anon-key assignments,
matched byte-for-byte with hex-escaped regular expressions, and one byte-exact
upstream anti-slop-swift README example. The workflow mutates every allowlisted
assignment with an `sb_secret_*` value, a generic high-entropy value, and a
changed publishable value; each must fail as `generic-api-key`. Supabase anon
keys are client-side publishable values; row-level security, not key secrecy,
protects the data.
Do not use these exceptions for service-role keys, access/refresh tokens, App
Store Connect private keys, or other credentials.

If a verified sample produces a false positive, add a rule-specific,
path-scoped and line-scoped exception with its reason, and add a regression
check when the exception could hide a changed value. Never allowlist a whole
directory or disable a detector just to make CI pass.
