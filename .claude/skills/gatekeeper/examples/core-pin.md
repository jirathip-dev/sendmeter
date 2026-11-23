# core/pin: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## comment-differs

Writes `.github/workflows/call.yml`:

```
name: call
on: push
permissions:
  contents: read
jobs:
  gates:
    uses: jirathip-dev/gatekeeper/.github/workflows/gates.yml@0123456789abcdef0123456789abcdef01234567 # v0.0.1
```

The gate fails and its log prints `the comment is v0.0.1`.

Fix: run ./.gatekeeper/run pin <version>, never edit the pin by hand; pass each secret by name, never secrets: inherit. Rerun: `./.gatekeeper/run check --gate core/pin`

## ref-is-a-tag

Writes `.github/workflows/call.yml`:

```
name: call
on: push
permissions:
  contents: read
jobs:
  gates:
    uses: jirathip-dev/gatekeeper/.github/workflows/gates.yml@v1.0.0 # v1.0.0
```

The gate fails and its log prints `is not a 40-hex commit`.

Fix: run ./.gatekeeper/run pin <version>, never edit the pin by hand; pass each secret by name, never secrets: inherit. Rerun: `./.gatekeeper/run check --gate core/pin`

## secrets-inherit

Writes `.github/workflows/call.yml`:

```
name: call
on: push
permissions:
  contents: read
jobs:
  local:
    uses: ./.github/workflows/ok.yml
    secrets: inherit
```

The gate fails and its log prints `secrets: inherit; pass each secret by name`.

Fix: run ./.gatekeeper/run pin <version>, never edit the pin by hand; pass each secret by name, never secrets: inherit. Rerun: `./.gatekeeper/run check --gate core/pin`

## sha-differs

Writes `.github/workflows/call.yml`:

```
name: call
on: push
permissions:
  contents: read
jobs:
  gates:
    uses: jirathip-dev/gatekeeper/.github/workflows/gates.yml@0123456789abcdef0123456789abcdef01234567 # v1.0.0
```

The gate fails and its log prints `the commit this gatekeeper was built from`.

Fix: run ./.gatekeeper/run pin <version>, never edit the pin by hand; pass each secret by name, never secrets: inherit. Rerun: `./.gatekeeper/run check --gate core/pin`

## wrapper-edited

Writes `.gatekeeper/run` (not shown).

The gate fails and its log prints `.gatekeeper/run differs from the wrapper`.

Fix: run ./.gatekeeper/run pin <version>, never edit the pin by hand; pass each secret by name, never secrets: inherit. Rerun: `./.gatekeeper/run check --gate core/pin`
