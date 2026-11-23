# core/hygiene: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## list-missing

With the environment:

```
DROVER_PRIVATE_NAMES=
```

The gate fails and its log prints `list-missing`.

Fix: take the private name out at the place the hit names; in CI pass the private-names secret, which drover hygiene push writes. Rerun: `./.gatekeeper/run check --gate core/hygiene`

## name-in-commit

Commits with the message:

```
tidy the notes

Asked by quillmoor.
```

The gate fails and its log prints `private-name #1 at commit`.

Fix: take the private name out at the place the hit names; in CI pass the private-names secret, which drover hygiene push writes. Rerun: `./.gatekeeper/run check --gate core/hygiene`

## name-in-pr-body

With the PR body (`{head}` is the case's commit):

```
Closes #1

For the quillmoor rollout.
```

The gate fails and its log prints `private-name #1 at PR body:3`.

Fix: take the private name out at the place the hit names; in CI pass the private-names secret, which drover hygiene push writes. Rerun: `./.gatekeeper/run check --gate core/hygiene`

## name-in-tree

Writes `notes.md`:

```
Ship it to the Quillmoor team.
```

The gate fails and its log prints `private-name #1 at notes.md:1`.

Fix: take the private name out at the place the hit names; in CI pass the private-names secret, which drover hygiene push writes. Rerun: `./.gatekeeper/run check --gate core/hygiene`
