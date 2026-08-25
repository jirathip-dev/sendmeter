# Security checks

## Secret scanning

`.github/workflows/secret-scan.yml` runs on every pull request and on pushes to
`main`. It installs gitleaks 8.30.1 from the versioned release archive, checks
the archive's SHA-256 digest, runs a disposable-fixture self-test, and then
scans the checked-out tree with `--no-git`. The gate deliberately checks current
files rather than replaying repository history; a credential that is found in a
working tree must still be removed and rotated, even if it was committed in the
past.

Run the same repository check locally with gitleaks installed:

```sh
gitleaks detect --source . --no-git --config .gitleaks.toml \
  --redact --no-banner --exit-code=1
```

The committed `.gitleaks.toml` contains only narrow, documented exceptions for
the two native files' Supabase publishable anon-key assignments and one
byte-exact upstream anti-slop-swift README example. Supabase anon keys are client-side
publishable values; row-level security, not key secrecy, protects the data.
Do not use these exceptions for service-role keys, access/refresh tokens, App
Store Connect private keys, or other credentials.

If a verified sample produces a false positive, add a rule-specific,
path-scoped and line-scoped exception with its reason, and add a regression
check when the exception could hide a changed value. Never allowlist a whole
directory or disable a detector just to make CI pass.
