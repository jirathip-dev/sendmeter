import * as Sentry from "@sentry/react";
import type { Breadcrumb, ErrorEvent, Event } from "@sentry/react";

// Error monitoring (issue #227, the decision from #10) — the ONLY class of bug
// this exists for is the one we currently cannot see at all: a JS exception on
// a phone we don't hold, a render crash, an unhandled rejection in a background
// sync. It does NOT catch silent failures: the #202 overnight logout, for
// instance, throws nothing and would never have produced an event here.
//
// Everything below is subtractive. The scrub is the point of the feature, not a
// detail of it: health data must never leave the device, so the event that
// leaves is built from an allow-list, and anything not explicitly allowed is
// dropped before the transport sees it.

// Build-time DSN. Absent (dev, tests, any build without the env var) => this
// module is completely inert and nothing is ever sent. Never committed.
const DSN = import.meta.env.VITE_SENTRY_DSN;

const REDACTED = "[redacted]";

/**
 * Health field names that must never leave the device — the `HealthMetric`
 * fields from `src/types.ts` plus the snake_case `health_metrics` column names
 * they're mapped from in `src/lib/repo/health.ts`. `weightKg` is the name the
 * spec uses for `bodyMassKg`; both spellings are listed so a future rename
 * can't quietly open a hole. Matching is word-bounded and case-insensitive, so
 * `zone` does not match `timezone`.
 */
const HEALTH_TERMS = [
  "hrvSdnnMs",
  "hrv_sdnn_ms",
  "restingHr",
  "resting_hr",
  "sleepHours",
  "sleep_hours",
  "sleepDeepHours",
  "sleep_deep_hours",
  "sleepRemHours",
  "sleep_rem_hours",
  "bodyMassKg",
  "body_mass_kg",
  "weightKg",
  "weight_kg",
  "respRateBpm",
  "resp_rate_bpm",
  "readiness",
  "zone",
  "health_metrics",
  "healthMetrics",
];

const HEALTH_RE = new RegExp(`\\b(?:${HEALTH_TERMS.join("|")})\\b`, "i");

/**
 * Context blocks worth keeping — none of these can carry user data. `culture`
 * (the SDK's default locale/timezone block) is deliberately absent: a timezone
 * is a coarse location signal, and the App Privacy answers say location is not
 * collected.
 */
const ALLOWED_CONTEXTS = ["app", "browser", "os", "device", "runtime", "react"];
/** The only `extra` keys we ever set deliberately. Everything else is dropped. */
const ALLOWED_EXTRA_KEYS = ["view", "route", "component"];
/** The only tags we ever set deliberately. */
const ALLOWED_TAGS = ["platform", "native", "build"];
/**
 * Breadcrumb categories that carry a URL/selector and nothing else. `console`
 * is deliberately absent — a console line can contain literally anything.
 */
const ALLOWED_BREADCRUMB_CATEGORIES = ["navigation", "fetch", "xhr", "ui.click"];
/** The only breadcrumb `data` keys kept, for the categories above. */
const ALLOWED_BREADCRUMB_DATA_KEYS = ["method", "url", "status_code", "from", "to"];
/**
 * Of those, the ones that are URLs by contract. They lose their query string
 * even when relative (`/dashboard?readiness=63`), which the URL-in-free-text
 * pass can't recognize because it has no scheme to anchor on.
 */
const URL_DATA_KEYS = ["url", "from", "to"];

/** Anything deeper than this is dropped rather than walked. */
const MAX_DEPTH = 8;

const URL_IN_TEXT_RE = /\b[a-z][a-z0-9+.-]*:\/\/[^\s"'<>]+/gi;

/** Drop the query string and fragment — they are the usual PII smuggling route. */
export function stripQuery(url: string): string {
  return url.split("#")[0]!.split("?")[0]!;
}

function containsHealthTerm(s: string): boolean {
  return HEALTH_RE.test(s);
}

/**
 * Free text: strip query strings out of any URL it contains, then redact the
 * whole string if it mentions a health field. Redacting wholesale (rather than
 * just the term) is what removes the *value* too — `"hrvSdnnMs=48.7"` and
 * `"hrvSdnnMs of 48.7 is out of range"` both go, without having to guess where
 * in the sentence the number lives.
 */
function redactText(s: string): string {
  const stripped = s.replace(URL_IN_TEXT_RE, (m) => stripQuery(m));
  return containsHealthTerm(stripped) ? REDACTED : stripped;
}

/**
 * Deep pass over whatever survived the allow-lists: any key naming a health
 * field takes its whole subtree with it, and any string mentioning one is
 * redacted. Belt-and-braces behind the allow-lists, not a substitute for them.
 */
function scrubDeep(value: unknown, depth = 0): unknown {
  if (typeof value === "string") return redactText(value);
  if (Array.isArray(value)) {
    if (depth >= MAX_DEPTH) return [];
    return value.map((v) => scrubDeep(v, depth + 1));
  }
  if (value && typeof value === "object") {
    if (depth >= MAX_DEPTH) return {};
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      if (containsHealthTerm(k)) continue;
      out[k] = scrubDeep(v, depth + 1);
    }
    return out;
  }
  return value;
}

function pickAllowed<T extends object>(
  obj: T | undefined,
  allowed: string[],
): T | undefined {
  if (!obj) return undefined;
  const out: Record<string, unknown> = {};
  for (const key of allowed) {
    const v = (obj as Record<string, unknown>)[key];
    if (v !== undefined) out[key] = v;
  }
  return Object.keys(out).length ? (out as T) : undefined;
}

/**
 * The `beforeBreadcrumb` hook. Returns null to drop the breadcrumb entirely.
 */
export function scrubBreadcrumb(crumb: Breadcrumb): Breadcrumb | null {
  const category = crumb.category ?? "";
  if (!ALLOWED_BREADCRUMB_CATEGORIES.includes(category)) return null;
  const data = pickAllowed(crumb.data, ALLOWED_BREADCRUMB_DATA_KEYS);
  if (data) {
    for (const key of URL_DATA_KEYS) {
      const v = data[key];
      if (typeof v === "string") data[key] = stripQuery(v);
    }
  }
  const out: Breadcrumb = {
    type: crumb.type,
    category,
    level: crumb.level,
    timestamp: crumb.timestamp,
    message: crumb.message,
    ...(data ? { data } : {}),
  };
  return scrubDeep(out) as Breadcrumb;
}

/**
 * The `beforeSend` hook. Rebuilds the event from an allow-list — identity is
 * the Supabase auth uuid and nothing else, the URL loses its query string, and
 * `extra` / `contexts` / `tags` / `breadcrumbs` keep only allow-listed entries.
 * What's left goes through {@link scrubDeep}.
 */
export function scrubEvent<T extends Event>(event: T): T {
  const e = event as Event;

  // Identity: the Supabase auth uuid only.
  // Never email, username, or ip.
  const id = e.user?.id;
  e.user = id ? { id: String(id) } : undefined;

  // Request: path only. No query string, no headers, no cookies, no body.
  if (e.request) {
    const url = typeof e.request.url === "string" ? stripQuery(e.request.url) : undefined;
    const method = e.request.method;
    e.request = { ...(url ? { url } : {}), ...(method ? { method } : {}) };
  }

  e.extra = pickAllowed(e.extra, ALLOWED_EXTRA_KEYS);
  e.contexts = pickAllowed(e.contexts, ALLOWED_CONTEXTS);
  e.tags = pickAllowed(e.tags, ALLOWED_TAGS);
  e.breadcrumbs = e.breadcrumbs
    ?.map(scrubBreadcrumb)
    .filter((b): b is Breadcrumb => b !== null);
  e.server_name = undefined;

  return scrubDeep(e) as T;
}

let started = false;

/**
 * Initialize Sentry — a no-op unless a build-time DSN is present, so dev, test
 * and any DSN-less build send nothing at all. Call once, before `createRoot`.
 *
 * `window.onerror` / `unhandledrejection` capture comes from Sentry's default
 * `GlobalHandlers` integration; the React `ErrorBoundary` covers render errors.
 */
export function initMonitoring(): void {
  if (started || !DSN) return;
  started = true;
  Sentry.init({
    dsn: DSN,
    // Which deploy this is (#239) — `vercel/preview`, `ios`, `local`, … See
    // `src/lib/deployEnv.ts`; `vite.config.ts` inlines it. `MODE` is only a
    // backstop: it reads `production` for every build, so relying on it mixed
    // preview and TestFlight errors into the real user stream.
    environment: import.meta.env.VITE_DEPLOY_ENV ?? import.meta.env.MODE,
    // No performance tracing, no session replay.
    tracesSampleRate: 0,
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 0,
    // `dataCollection` is v10's replacement for the (deprecated) `sendDefaultPii`
    // and is stricter: instead of one "no PII" flag it switches each collector
    // off at the source, before beforeSend ever sees the data. `userInfo: false`
    // means the SDK never infers a user — `setMonitoringUser` sets the auth uuid
    // and that is the only identity that exists. `stackFrameVariables: false`
    // matters most: it defaults to ON, and a captured local could be a whole
    // HealthMetric.
    dataCollection: {
      userInfo: false,
      cookies: false,
      httpHeaders: { request: false, response: false },
      httpBodies: [],
      urlQueryParams: false,
      stackFrameVariables: false,
      databaseQueryData: false,
    },
    // Session (release-health) envelopes are sent by the SDK directly and never
    // pass through beforeSend — drop the integration so EVERY outbound envelope
    // is one the scrub has seen.
    integrations: (defaults) => defaults.filter((i) => i.name !== "BrowserSession"),
    beforeSend: (event: ErrorEvent) => scrubEvent(event),
    // Nothing produces transactions today (tracesSampleRate is 0), but they are
    // a second event type with its own hook — wire the same scrub in now so
    // turning tracing on later can't quietly open an unscrubbed channel.
    beforeSendTransaction: (event) => scrubEvent(event),
    beforeBreadcrumb: (crumb: Breadcrumb) => scrubBreadcrumb(crumb),
  });
}

/** Attach (or clear) the Supabase auth uuid. Never the email. */
export function setMonitoringUser(userId: string | null): void {
  if (!started) return;
  Sentry.setUser(userId ? { id: userId } : null);
}

/**
 * Report user data that was lost because a durable write refused (#264) — the
 * one failure class that produces no exception, no stack and no retry, so
 * nothing else here would ever see it.
 *
 * `what` must be a CONSTANT the code chose (e.g. `"tindeq-recording:
 * salvage-on-unmount"`), never anything derived from user input, and `detail`
 * is restricted to numbers/booleans by type so a future caller cannot smuggle
 * a free-text value in through it. Both are folded into the message rather
 * than into `extra`, whose allow-list would drop them; the message still goes
 * through `beforeSend`'s scrub like everything else.
 */
export function captureDataLoss(
  what: string,
  detail: Record<string, number | boolean> = {},
): void {
  if (!started) return;
  const parts = Object.entries(detail).map(([k, v]) => `${k}=${v}`);
  Sentry.captureMessage(
    `data-loss: ${what}${parts.length ? ` (${parts.join(", ")})` : ""}`,
    "error",
  );
}

/** Report an uncaught render error from the ErrorBoundary. */
export function captureAppError(error: unknown, componentStack?: string): void {
  if (!started) return;
  Sentry.captureException(
    error,
    componentStack ? { contexts: { react: { componentStack } } } : undefined,
  );
}
