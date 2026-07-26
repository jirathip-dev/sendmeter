/**
 * Which deploy a bundle came from — the value of Sentry's `environment` tag
 * (issue #239).
 *
 * `import.meta.env.MODE` cannot answer this. `npm run build` is a plain
 * `vite build` with no `--mode`, which Vite defaults to `production`, so a
 * Vercel *preview* deploy and the TestFlight archive both reported
 * `production` and mixed into the real user error stream. The real signal is
 * `VERCEL_ENV`, which Vercel sets on every build but Vite does not forward to
 * client code (only `VITE_`-prefixed vars are) — hence the `define` in
 * `vite.config.ts` that inlines the result of this function.
 *
 * This runs in **Node, at vite-config time**: keep it pure and import nothing
 * browser-only.
 */

/** The `process.env`-shaped input. Only the two keys that matter. */
export interface DeployEnvVars {
  /** Vercel sets this on every build: `production` | `preview` | `development`. */
  VERCEL_ENV?: string | undefined;
  /** Explicit override for builds Vercel knows nothing about (TestFlight = `ios`). */
  VITE_DEPLOY_ENV?: string | undefined;
}

/** What a build with no environment information at all reports. */
export const DEFAULT_DEPLOY_ENV = "local";

/** Declared-but-empty is the usual way a CI env var arrives as `""` — treat it as unset. */
function present(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

/**
 * Resolve the deploy environment: explicit override, then Vercel's own value,
 * then `local`.
 *
 * The explicit override deliberately outranks `VERCEL_ENV`: Vercel always sets
 * `VERCEL_ENV`, so the other order would make `VITE_DEPLOY_ENV` a no-op on the
 * one platform where you might want to override it.
 */
export function resolveDeployEnv(env: DeployEnvVars = {}): string {
  return (
    present(env.VITE_DEPLOY_ENV) ?? present(env.VERCEL_ENV) ?? DEFAULT_DEPLOY_ENV
  );
}
