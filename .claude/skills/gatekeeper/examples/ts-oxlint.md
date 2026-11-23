# ts/oxlint: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## any

Writes `src/case.ts`:

```
export function id(x: any): number {
  return x;
}
```

The gate fails and its log prints `typescript(no-explicit-any)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## as-cast

Writes `src/case.ts`:

```
export const n = JSON.parse("1") as number;
```

The gate fails and its log prints `typescript(consistent-type-assertions)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## console-log

Writes `src/case.ts`:

```
export function log(s: string): void {
  console.log(s);
}
```

The gate fails and its log prints `eslint(no-console)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## default-export

Writes `src/case.ts`:

```
export default function one(): number {
  return 1;
}
```

The gate fails and its log prints `import(no-default-export)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## enum

Writes `src/case.ts`:

```
export enum Colour {
  Red = "red",
}
```

The gate fails and its log prints `gatekeeper(no-enum)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## eval

Writes `src/case.ts`:

```
export function run(s: string): unknown {
  return eval(s);
}
```

The gate fails and its log prints `eslint(no-eval)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## inner-html

Writes `src/case.ts`:

```
export function show(el: HTMLElement, s: string): void {
  el.innerHTML = s;
}
```

The gate fails and its log prints `'innerHTML' is restricted`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## insert-adjacent-html

Writes `src/case.ts`:

```
export function add(el: HTMLElement, s: string): void {
  el.insertAdjacentHTML("beforeend", s);
}
```

The gate fails and its log prints `'insertAdjacentHTML' is restricted`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## new-function

Writes `src/case.ts`:

```
export const f = new Function("a", "return a");
```

The gate fails and its log prints `eslint(no-new-func)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-else-return

Writes `src/case.ts`:

```
export function f(x: boolean): number {
  if (x) {
    return 1;
  } else {
    return 2;
  }
}
```

The gate fails and its log prints `eslint(no-else-return)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-empty

Writes `src/case.ts`:

```
export function f(x: boolean): void {
  if (x) {
  }
}
```

The gate fails and its log prints `eslint(no-empty)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-inferrable-types

Writes `src/case.ts`:

```
export const n: number = 1;
```

The gate fails and its log prints `typescript(no-inferrable-types)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-lonely-if

Writes `src/case.ts`:

```
export function f(a: boolean, b: boolean): number {
  let n = 0;
  if (a) {
    n = 1;
  } else {
    if (b) {
      n = 2;
    }
  }
  return n;
}
```

The gate fails and its log prints `eslint(no-lonely-if)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-nested-ternary

Writes `src/case.ts`:

```
export function f(a: boolean, b: boolean): number {
  return a ? 1 : b ? 2 : 3;
}
```

The gate fails and its log prints `eslint(no-nested-ternary)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-unneeded-ternary

Writes `src/case.ts`:

```
export function f(x: boolean): boolean {
  return x ? true : false;
}
```

The gate fails and its log prints `eslint(no-unneeded-ternary)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-unused-vars

Writes `src/case.ts`:

```
const unused = 1;
export const n = 2;
```

The gate fails and its log prints `eslint(no-unused-vars)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-useless-catch

Writes `src/case.ts`:

```
export function f(): unknown {
  try {
    return JSON.parse("x");
  } catch (e) {
    throw e;
  }
}
```

The gate fails and its log prints `eslint(no-useless-catch)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-useless-constructor

Writes `src/case.ts`:

```
export class Thing {
  constructor() {}
}
```

The gate fails and its log prints `eslint(no-useless-constructor)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-useless-promise-resolve-reject

Writes `src/case.ts`:

```
export async function f(): Promise<number> {
  return Promise.resolve(1);
}
```

The gate fails and its log prints `unicorn(no-useless-promise-resolve-reject)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-useless-rename

Writes `src/case.ts`:

```
export function f({ a: a }: { a: number }): number {
  return a;
}
```

The gate fails and its log prints `eslint(no-useless-rename)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-useless-return

Writes `src/case.ts`:

```
export function f(xs: number[]): void {
  xs.push(1);
  return;
}
```

The gate fails and its log prints `eslint(no-useless-return)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-useless-spread

Writes `src/case.ts`:

```
export const xs = [...[1, 2]];
```

The gate fails and its log prints `unicorn(no-useless-spread)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-useless-undefined

Writes `src/case.ts`:

```
export function f(g: (n?: number) => void): void {
  g(undefined);
}
```

The gate fails and its log prints `unicorn(no-useless-undefined)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## no-warning-comments

Writes `src/case.ts`:

```
// TODO: finish this
export const n = 1;
```

The gate fails and its log prints `eslint(no-warning-comments)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## non-null

Writes `src/case.ts`:

```
export function first(xs: number[]): number {
  return xs.at(0)!;
}
```

The gate fails and its log prints `typescript(no-non-null-assertion)`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## outer-html

Writes `src/case.ts`:

```
export function swap(el: HTMLElement, s: string): void {
  el.outerHTML = s;
}
```

The gate fails and its log prints `'outerHTML' is restricted`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## ts-expect-error

Writes `src/case.ts`:

```
// @ts-expect-error: wrong on purpose
export const n: string = 1;
```

The gate fails and its log prints `Do not use @ts-expect-error`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`

## ts-ignore

Writes `src/case.ts`:

```
// @ts-ignore
export const n = 1;
```

The gate fails and its log prints `@ts-ignore`.

Fix: rewrite the line oxlint names: narrow with a type guard, parse at the edge, use textContent or DOM nodes, named exports and string unions; never disable the rule. Rerun: `./.gatekeeper/run check --gate ts/oxlint`
