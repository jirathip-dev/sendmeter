# core/cap: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## cap-missing

Removes `ci/cap.toml`.

The gate fails and its log prints `No such file or directory`.

Fix: delete code; a raise of the cap is its own issue. Rerun: `./.gatekeeper/run check --gate core/cap`

## over-cap

Writes `ci/cap.toml`:

```
[fleet.fixture]
line_cap = 2
```

The gate fails and its log prints `/ cap 2`.

Fix: delete code; a raise of the cap is its own issue. Rerun: `./.gatekeeper/run check --gate core/cap`
