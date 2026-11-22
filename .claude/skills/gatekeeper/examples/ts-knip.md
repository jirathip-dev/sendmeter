# ts/knip: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## stale

Writes `.gatekeeper/baseline/ts-knip.txt`:

```
src/gone.ts: files: src/gone.ts
```

The gate fails and its log prints `stale: shrink the baseline`.

Fix: delete the unused file, export or dependency knip names; once one is fixed, shrink the list: ./.gatekeeper/run baseline ts/knip. Rerun: `./.gatekeeper/run check --gate ts/knip`

## unused-dependency

Writes `package.json`:

```
{
  "name": "gatekeeper-ts-fixture",
  "private": true,
  "type": "module",
  "exports": "./src/index.ts",
  "dependencies": {
    "left-pad": "1.3.0"
  },
  "devDependencies": {
    "typescript": "5.9.3"
  }
}
```

The gate fails and its log prints `package.json: dependencies: left-pad`.

Fix: delete the unused file, export or dependency knip names; once one is fixed, shrink the list: ./.gatekeeper/run baseline ts/knip. Rerun: `./.gatekeeper/run check --gate ts/knip`

## unused-export

Writes `src/math.ts`:

```
export function double(n: number): number {
  return n * 2;
}

export function triple(n: number): number {
  return n * 3;
}
```

The gate fails and its log prints `src/math.ts: exports: triple`.

Fix: delete the unused file, export or dependency knip names; once one is fixed, shrink the list: ./.gatekeeper/run baseline ts/knip. Rerun: `./.gatekeeper/run check --gate ts/knip`

## unused-file

Writes `src/orphan.ts`:

```
export const orphan = 1;
```

The gate fails and its log prints `src/orphan.ts: files: src/orphan.ts`.

Fix: delete the unused file, export or dependency knip names; once one is fixed, shrink the list: ./.gatekeeper/run baseline ts/knip. Rerun: `./.gatekeeper/run check --gate ts/knip`
