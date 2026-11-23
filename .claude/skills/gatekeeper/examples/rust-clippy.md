# rust/clippy: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## pedantic-warning

Writes `src/lib.rs`:

```
pub fn one() -> u32 {
    1
}
```

The gate fails and its log prints `must_use_candidate`.

Fix: return the error; only tests may unwrap, panic, index or print; never allow a pedantic lint to pass. Rerun: `./.gatekeeper/run check --gate rust/clippy`

## rustc-warning

Writes `src/lib.rs`:

```
#[must_use]
pub fn add(a: u32, b: u32) -> Option<u32> {
    a.checked_add(b)
}

fn unused() {}
```

The gate fails and its log prints `never used`.

Fix: return the error; only tests may unwrap, panic, index or print; never allow a pedantic lint to pass. Rerun: `./.gatekeeper/run check --gate rust/clippy`
