# core/actionlint: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## bad-workflow

Writes `.github/workflows/bad.yml`:

```
name: bad
on: push
permissions:
  contents: read
jobs:
  bad:
    runs-on: ubuntu-latest
    steps:
      - run: echo ${{ github.nope }}
```

The gate fails and its log prints `property "nope" is not defined`.

Fix: fix the workflow at the line actionlint names. Rerun: `./.gatekeeper/run check --gate core/actionlint`
