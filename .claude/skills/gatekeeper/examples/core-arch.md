# core/arch: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## ban-hit

Writes `crates/low/src/lib.rs`:

```
pub fn low() -> u32 {
    1
}

pub fn quit() {
    std::process::exit(1)
}
```

The gate fails and its log prints `is banned here`.

Fix: follow the rule the finding names; rerun the generator, never hand-edit a generated file. Rerun: `./.gatekeeper/run check --gate core/arch`

## comment-added

Writes `crates/low/src/lib.rs`:

```
pub fn low() -> u32 {
    // one
    1
}
```

The gate fails and its log prints `a comment`.

Fix: follow the rule the finding names; rerun the generator, never hand-edit a generated file. Rerun: `./.gatekeeper/run check --gate core/arch`

## file-too-long

Writes `crates/low/src/lib.rs` (not shown).

The gate fails and its log prints `over 20`.

Fix: follow the rule the finding names; rerun the generator, never hand-edit a generated file. Rerun: `./.gatekeeper/run check --gate core/arch`

## frozen-line-added

Writes `list.txt`:

```
a
b
```

The gate fails and its log prints `added to a frozen list`.

Fix: follow the rule the finding names; rerun the generator, never hand-edit a generated file. Rerun: `./.gatekeeper/run check --gate core/arch`

## generated-stale

Writes `gen.txt`:

```
edited by hand
```

The gate fails and its log prints `differs from what`.

Fix: follow the rule the finding names; rerun the generator, never hand-edit a generated file. Rerun: `./.gatekeeper/run check --gate core/arch`

## layer-crossed

Writes `crates/low/src/lib.rs`:

```
pub fn low() -> u32 {
    high::high()
}
```

The gate fails and its log prints `layer `low` uses `high``.

Fix: follow the rule the finding names; rerun the generator, never hand-edit a generated file. Rerun: `./.gatekeeper/run check --gate core/arch`
