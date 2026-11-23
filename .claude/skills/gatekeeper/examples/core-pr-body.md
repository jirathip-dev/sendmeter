# core/pr-body: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## generated-with

With the PR body (`{head}` is the case's commit):

```
Closes #1

## For humans

The notes are tidier.

Evidence at {head}.

Generated with a tool
```

The gate fails and its log prints `carries `Generated with a tool``.

Fix: edit the PR body: name the pushed head sha, add a `## For humans` section, drop the "Generated with" line. Rerun: `./.gatekeeper/run check --gate core/pr-body`

## names-the-head

With the PR body (`{head}` is the case's commit):

```
Closes #1

## For humans

The notes are tidier.

Evidence at {head}.
```

The gate passes.

## no-for-humans

With the PR body (`{head}` is the case's commit):

```
Closes #1

The notes are tidier.

Evidence at {head}.
```

The gate fails and its log prints `has no `## For humans` section`.

Fix: edit the PR body: name the pushed head sha, add a `## For humans` section, drop the "Generated with" line. Rerun: `./.gatekeeper/run check --gate core/pr-body`

## no-head-sha

With the PR body (`{head}` is the case's commit):

```
Closes #1

## For humans

The notes are tidier.
```

The gate fails and its log prints `evidence names no sha of head`.

Fix: edit the PR body: name the pushed head sha, add a `## For humans` section, drop the "Generated with" line. Rerun: `./.gatekeeper/run check --gate core/pr-body`
