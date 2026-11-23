---
name: gatekeeper
description: Read, fix and rerun a failing gatekeeper gate (gatekeeper 1.1.2).
---

# gatekeeper 1.1.2

`./.gatekeeper/run check` is what CI runs and what a lane runs. A failing gate prints `FAIL  <pack>/<gate>`, its log's tail, its `fix:` line, its log path and the command that reruns it alone.

1. Read the gate's entry in its pack file below: what it checks and how to fix it.
2. Fix the cause, never the gate: no pack file is copied into the repo or edited there.
3. Rerun the one gate: `./.gatekeeper/run check --gate <pack>/<gate>`, then `./.gatekeeper/run check`.

`./.gatekeeper/run list` prints the planned gates with their budgets and why one is skipped. A repo's own gates live in `.gatekeeper/gates/<gate>.toml` as `local/<gate>` and print their `fix` the same way.

With `[cache]` in `.gatekeeper/config.toml` a gate whose inputs already passed prints `cached` with the run that proved it. A rerun of a cached pass that fails now prints `cached pass does not hold`: the gate reads a file it does not declare; add it to the gate's `paths` or set `cache = false`. `--no-cache` runs and records nothing. A `projects` gate keeps one record per project, over that project, every project it needs and every file outside all projects that `[scope] ignore` keeps: a change reruns the projects it reaches, and the row says how many ran and how many were cached. A sharded CI job keeps one record for its whole set of projects and is cached only while that set and its files are unchanged.

A gate with `[select]` runs only the test files a change can reach, passed to its `run` line in place of `{files}`. Its row prints `selected N of M test files in Xs:` with a count per rule (closure, always, readers, project-readers, widened), or `selected all M test files:` and why, then `list: target/gatekeeper/<pack>-<gate>.selection.json`. Why did a test run, or not? That file names each selected file with every rule that selected it: `closure` (vitest lists its imports reaching a changed file), `always`, `reads` (its code names a changed file's path or basename, or it walks that file's project or a directory above it), `names-project`, `widened` (a deleted file's project or import specifier). Rerun a failing test with the same command: the same tree and base select the same files. A selection that cannot be computed fails the gate with its `.select.log`; it never runs fewer tests. A sharded `[select]` gate writes vitest's JSON report to `{report}`; each CI shard selects the same list and runs its slice, split by the times the last push to the integration branch recorded. `ci done` fails a gate whose shards selected different lists (rerun all jobs), and a shard no file fell into prints `skip` and passes. `./.gatekeeper/run replay --gate <pack>/<gate> --runs runs.jsonl --other '<cmd> {base}'` measures it against another selector: each line of `runs.jsonl` is `{"pr", "base", "head", "failed"}`, both select in a scratch worktree of the head, and it prints per run the counts, the files only one chose and each missed failure, then the totals, into `target/gatekeeper/replay/`; it exits 1 when gatekeeper missed a failure.

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
- `farrier` git-04d7a80, built by gatekeeper for x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu, aarch64-apple-darwin (`bin/farrier`)
- `libde265` 1.0.16, built by gatekeeper for x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu, aarch64-apple-darwin (`lib/pkgconfig/libde265.pc`)
- `sqlx-cli` 0.8.6, built by gatekeeper for x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu, aarch64-apple-darwin (`bin/sqlx`)
- `cargo-deny` 0.22.0
- `supabase` 3.2.0
- `anti-slop-swift` 1.0.0, built by gatekeeper for aarch64-apple-darwin (`bin/anti-slop`)
- `knip` 6.47.0
- `oxlint` 1.94.0
