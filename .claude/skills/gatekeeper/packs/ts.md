# The ts pack

tsc strict, oxlint with the bans and the anti-slop rules, knip's unused-code ratchet

## ts/knip

pinned knip with the repo's own knip config: no unused file, export or dependency beyond the baseline

- fix: delete the unused file, export or dependency knip names; once one is fixed, shrink the list: ./.gatekeeper/run baseline ts/knip
- budget: 60s
- cached: yes
- rerun: `./.gatekeeper/run check --gate ts/knip`
- what a failure looks like: [ts-knip](../examples/ts-knip.md)

## ts/oxlint

pinned oxlint over the [ts] projects with the pack's config by reference: no as-casts, non-null !, any, ts-ignore or ts-expect-error, HTML sinks, eval, new Function, console, default exports or enums; and the 15 anti-slop rules

- fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule
- budget: 30s
- cached: yes
- rerun: `./.gatekeeper/run check --gate ts/oxlint`
- what a failure looks like: [ts-oxlint](../examples/ts-oxlint.md)

## ts/tsc

after the [ts] install, each [ts] project's tsconfig has strict on and no strict flag switched off; then tsc --noEmit -p

- fix: turn strict back on and drop the flag that switches part of it off, then fix the type error tsc names
- budget: 90s
- cached: yes
- rerun: `./.gatekeeper/run check --gate ts/tsc`
- what a failure looks like: [ts-tsc](../examples/ts-tsc.md)
