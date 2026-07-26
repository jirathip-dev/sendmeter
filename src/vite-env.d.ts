/// <reference types="vite/client" />

interface ImportMetaEnv {
  // Supabase overrides for local/preview builds (see src/lib/supabase.ts).
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_SUPABASE_ANON_KEY?: string;
  // Sentry DSN (#227). Injected at build time by Vercel/CI — never committed.
  // Absent => monitoring is inert and nothing is sent.
  readonly VITE_SENTRY_DSN?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
