# rust/fmt: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## unformatted

Writes `src/lib.rs`:

```
#[must_use]
pub fn add(a: u32, b: u32) -> Option<u32> { a.checked_add(b) }
```

The gate fails and its log prints `Diff in`.

Fix: run cargo fmt --all and commit the result. Rerun: `./.gatekeeper/run check --gate rust/fmt`
