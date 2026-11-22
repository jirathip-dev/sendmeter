# rust/bans: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## floor-allowed

Writes `Cargo.toml` (not shown).

The gate fails and its log prints `unwrap_used is "allow"`.

Fix: put the lint back in [workspace.lints] at the floor's level; a floor that is wrong is changed in gatekeeper. Rerun: `./.gatekeeper/run check --gate rust/bans`

## floor-missing

Writes `Cargo.toml` (not shown).

The gate fails and its log prints `has no unwrap_used`.

Fix: put the lint back in [workspace.lints] at the floor's level; a floor that is wrong is changed in gatekeeper. Rerun: `./.gatekeeper/run check --gate rust/bans`

## pedantic-off

Writes `Cargo.toml` (not shown).

The gate fails and its log prints `pedantic is "allow"`.

Fix: put the lint back in [workspace.lints] at the floor's level; a floor that is wrong is changed in gatekeeper. Rerun: `./.gatekeeper/run check --gate rust/bans`
