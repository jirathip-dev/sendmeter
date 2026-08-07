/// <reference types="vite/client" />

interface ImportMetaEnv {
  // Supabase overrides for local/preview builds (see src/lib/supabase.ts).
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_SUPABASE_ANON_KEY?: string;
  // Sentry DSN (#227). Injected at build time by Vercel/CI — never committed.
  // Absent => monitoring is inert and nothing is sent.
  readonly VITE_SENTRY_DSN?: string;
  // Which deploy this bundle is (#239) — the Sentry `environment` tag.
  // Not read from the shell: `vite.config.ts` inlines it via `define` from
  // `resolveDeployEnv` (src/lib/deployEnv.ts), so it is always present in a
  // bundle built by this config. Optional here so `monitoring.ts` keeps its
  // `?? MODE` backstop for anything that compiles the module another way.
  readonly VITE_DEPLOY_ENV?: string;
  // #484: a value that changes on every `vite build` — see
  // `appVersion.ts#currentAppVersion`. Always present in a bundle built by
  // this config (same "inlined via define" story as VITE_DEPLOY_ENV above);
  // optional here for the same reason.
  readonly VITE_BUILD_ID?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
