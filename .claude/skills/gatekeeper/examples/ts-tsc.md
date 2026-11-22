# ts/tsc: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## strict-flag-off

Writes `tsconfig.json`:

```
{
  "compilerOptions": {
    "strict": true,
    "strictNullChecks": false,
    "noEmit": true,
    "target": "es2022",
    "module": "preserve",
    "lib": ["es2022", "dom"],
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

The gate fails and its log prints `switches strictNullChecks off`.

Fix: turn strict back on and drop the flag that switches part of it off, then fix the type error tsc names. Rerun: `./.gatekeeper/run check --gate ts/tsc`

## strict-off

Writes `tsconfig.json`:

```
{
  "compilerOptions": {
    "strict": false,
    "noEmit": true,
    "target": "es2022",
    "module": "preserve",
    "lib": ["es2022", "dom"],
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

The gate fails and its log prints `tsconfig.json: does not set "strict": true`.

Fix: turn strict back on and drop the flag that switches part of it off, then fix the type error tsc names. Rerun: `./.gatekeeper/run check --gate ts/tsc`

## type-error

Writes `src/bad.ts`:

```
export const n: number = "one";
```

The gate fails and its log prints `error TS2322`.

Fix: turn strict back on and drop the flag that switches part of it off, then fix the type error tsc names. Rerun: `./.gatekeeper/run check --gate ts/tsc`
