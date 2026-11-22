---
name: gatekeeper
description: Read, fix and rerun a failing gatekeeper gate (gatekeeper 1.1.0).
---

# gatekeeper 1.1.0

`./.gatekeeper/run check` is what CI runs and what a lane runs. A failing gate prints `FAIL  <pack>/<gate>`, its log's tail, its `fix:` line, its log path and the command that reruns it alone.

1. Read the gate's entry in its pack file below: what it checks and how to fix it.
2. Fix the cause, never the gate: no pack file is copied into the repo or edited there.
3. Rerun the one gate: `./.gatekeeper/run check --gate <pack>/<gate>`, then `./.gatekeeper/run check`.

`./.gatekeeper/run list` prints the planned gates with their budgets and why one is skipped. A repo's own gates live in `.gatekeeper/gates/<gate>.toml` as `local/<gate>` and print their `fix` the same way.

With `[cache]` in `.gatekeeper/config.toml` a gate whose inputs already passed prints `cached` with the run that proved it. A rerun of a cached pass that fails now prints `cached pass does not hold`: the gate reads a file it does not declare; add it to the gate's `paths` or set `cache = false`. `--no-cache` runs and records nothing. A `projects` gate keeps one record per project, over that project, every project it needs and every file outside all projects that `[scope] ignore` keeps: a change reruns the projects it reaches, and the row says how many ran and how many were cached. A sharded CI job keeps one record for its whole set of projects and is cached only while that set and its files are unchanged.

## Packs

- [core](packs/core.md): the line cap, the rules file, arch-check, actionlint, the dependency list
- [rust](packs/rust.md): fmt, clippy with the shared lints, cargo-deny, the banned-API fixtures
- [swift](packs/swift.md): the prebuilt anti-slop-swift, warnings as errors under GATEKEEPER_STRICT=1, the raw colour and size lint
- [ts](packs/ts.md): tsc strict, oxlint with the bans and the anti-slop rules, knip's unused-code ratchet
- [supabase](packs/supabase.md): the migration files' names, order and policy rule, and pgTAP on a local stack (CI only on a lane's host)

## Pinned tools

A gate's `run` line names one as `{tool:<name>}`: gatekeeper fetches it by version, checks its sha256 and puts the cached path there, on a lane's host and on a runner alike. A tool with no upstream binary is built once per version by gatekeeper's `tools` workflow; never build it from source in a repo's CI.

- `actionlint` 1.7.12
- `drover` build-staging-04ae328
- `libde265` 1.0.16, built by gatekeeper for x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu, aarch64-apple-darwin (`lib/pkgconfig/libde265.pc`)
- `sqlx-cli` 0.8.6, built by gatekeeper for x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu, aarch64-apple-darwin (`bin/sqlx`)
- `cargo-deny` 0.22.0
- `supabase` 3.2.0
- `anti-slop-swift` 1.0.0, built by gatekeeper for aarch64-apple-darwin (`bin/anti-slop`)
- `knip` 6.47.0
- `oxlint` 1.94.0
