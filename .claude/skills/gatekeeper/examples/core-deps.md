# core/deps: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## empty-reason

Writes `.gatekeeper/deps.toml`:

```
growth = 10

[cargo]
proptest = "property tests of the parser"
serde = "parse the config"

[npm]
react = "the UI"
typescript = "type-check the UI"

[swift]
swift-argument-parser = ""
```

The gate fails and its log prints `[swift] swift-argument-parser: empty reason`.

Fix: ask the owner before you add a dependency; then list it with its reason, drop a stale entry, and for growth over the limit put `Deps: #<issue> <the owner's answer>` in a commit message. Rerun: `./.gatekeeper/run check --gate core/deps`

## growth-raised

Writes `.gatekeeper/deps.toml`:

```
growth = 20

[cargo]
proptest = "property tests of the parser"
serde = "parse the config"

[npm]
react = "the UI"
typescript = "type-check the UI"

[swift]
swift-argument-parser = "parse the command line"
```

Writes `pnpm-lock.yaml` (not shown).

The gate fails and its log prints `over the limit of 10`.

Fix: ask the owner before you add a dependency; then list it with its reason, drop a stale entry, and for growth over the limit put `Deps: #<issue> <the owner's answer>` in a commit message. Rerun: `./.gatekeeper/run check --gate core/deps`

## lockfile-plus-11

Writes `pnpm-lock.yaml` (not shown).

The gate fails and its log prints `lockfiles grew by 11 packages, over the limit of 10`.

Fix: ask the owner before you add a dependency; then list it with its reason, drop a stale entry, and for growth over the limit put `Deps: #<issue> <the owner's answer>` in a commit message. Rerun: `./.gatekeeper/run check --gate core/deps`

## lockfile-plus-11-bad-deps-line

Commits with the message:

```
add the chart library

Deps: the owner said yes
```

Writes `pnpm-lock.yaml` (not shown).

The gate fails and its log prints ``Deps: the owner said yes` names no `#<issue>` and answer`.

Fix: ask the owner before you add a dependency; then list it with its reason, drop a stale entry, and for growth over the limit put `Deps: #<issue> <the owner's answer>` in a commit message. Rerun: `./.gatekeeper/run check --gate core/deps`

## lockfile-plus-11-with-deps-line

Commits with the message:

```
add the chart library

Deps: #42 owner: yes, the chart library and its 11 packages
```

Writes `pnpm-lock.yaml` (not shown).

The gate passes.

## no-list

Removes `.gatekeeper/deps.toml`.

The gate fails and its log prints `wrote it with an empty reason for each of the 5 direct dependencies`.

Fix: ask the owner before you add a dependency; then list it with its reason, drop a stale entry, and for growth over the limit put `Deps: #<issue> <the owner's answer>` in a commit message. Rerun: `./.gatekeeper/run check --gate core/deps`

## stale-entry

Writes `.gatekeeper/deps.toml`:

```
growth = 10

[cargo]
proptest = "property tests of the parser"
serde = "parse the config"

[npm]
react = "the UI"
typescript = "type-check the UI"
left-pad = "pad strings"

[swift]
swift-argument-parser = "parse the command line"
```

The gate fails and its log prints `[npm] left-pad: stale`.

Fix: ask the owner before you add a dependency; then list it with its reason, drop a stale entry, and for growth over the limit put `Deps: #<issue> <the owner's answer>` in a commit message. Rerun: `./.gatekeeper/run check --gate core/deps`

## unlisted-direct

Writes `app/Cargo.toml`:

```
[package]
name = "app"
version = "0.1.0"
edition = "2024"

[dependencies]
serde.workspace = true
shared.workspace = true

[dev-dependencies]
proptest = "1"
anyhow = "1"
```

The gate fails and its log prints `[cargo] anyhow: unlisted direct dependency`.

Fix: ask the owner before you add a dependency; then list it with its reason, drop a stale entry, and for growth over the limit put `Deps: #<issue> <the owner's answer>` in a commit message. Rerun: `./.gatekeeper/run check --gate core/deps`
