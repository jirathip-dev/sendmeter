# The rust pack

fmt, clippy with the shared lints, cargo-deny, the banned-API fixtures

## rust/bans

the 12 clippy denies, unsafe_code forbid and pedantic warn are in [workspace.lints]; clippy refuses each banned-API file under them

- fix: put the lint back in [workspace.lints] at the floor's level; a floor that is wrong is changed in gatekeeper
- budget: 30s
- cached: yes
- rerun: `./.gatekeeper/run check --gate rust/bans`
- what a failure looks like: [rust-bans](../examples/rust-bans.md)

## rust/clippy

clippy with the repo's lints (pedantic and the bans), -D warnings, the pack's clippy.toml by reference; tests may unwrap, panic, index and print

- fix: return the error; only tests may unwrap, panic, index or print; never allow a pedantic lint to pass
- budget: 180s
- cached: yes
- rerun: `./.gatekeeper/run check --gate rust/clippy`
- what a failure looks like: [rust-clippy](../examples/rust-clippy.md)

## rust/deny

deny.toml holds the floor (yanked, duplicates, wildcards, unknown sources denied; shared licences), then cargo deny check

- fix: deny what the floor denies, pin the dependency to a version, or drop the crate whose licence is outside the list
- budget: 20s
- cached: no, cache = false
- rerun: `./.gatekeeper/run check --gate rust/deny`
- what a failure looks like: [rust-deny](../examples/rust-deny.md)

## rust/fmt

cargo fmt --check under the repo's rustfmt.toml

- fix: run cargo fmt --all and commit the result
- budget: 10s
- cached: yes
- rerun: `./.gatekeeper/run check --gate rust/fmt`
- what a failure looks like: [rust-fmt](../examples/rust-fmt.md)
