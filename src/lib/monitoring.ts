import * as Sentry from "@sentry/react";
import type { Breadcrumb, ErrorEvent, Event } from "@sentry/react";
import { isZeroRowMutationError } from "./mutationInvariant";

// Error monitoring (issues #227/#382, the decision from #10): JS exceptions on
// phones we don't hold plus a narrow allow-list of handled operational failures
// after recovery is exhausted. It does NOT catch every silent failure: the #202
// overnight logout, for instance, throws nothing and has its own bounded local
// diagnostics rather than a Sentry event.
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
 * (the SDK's default locale/timezone block) is deliberately absent: unlike
 * the rounded coarse coordinates Send Conditions sends to Open-Meteo (only
 * when Send Conditions is used), a timezone would leak on every single
 * event regardless of whether the user ever opens Send Conditions.
 */
const ALLOWED_CONTEXTS = ["app", "browser", "os", "device", "runtime", "react"];
/** The only `extra` keys we ever set deliberately. Everything else is dropped. */
const ALLOWED_EXTRA_KEYS = [
  "view",
  "route",
  "component",
  // Handled operational failures (#382): every value is runtime-checked to
  // remain numeric/boolean by captureHandledOperationalFailure.
  "retry_attempts",
  "automatic",
  "affected_rows",
  "status",
];
/** The only tags we ever set deliberately. */
const ALLOWED_TAGS = [
  "platform",
  "native",
  "build",
  // Closed values owned by captureHandledOperationalFailure (#382).
  "operation",
  "failure_class",
  "outcome",
];
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
  scrubHandledFailureFields(e);
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
 * Report user data that was lost because a durable write refused (#264). This
 * remains separate from handled operational failures: it means the fallback
 * storage itself failed and data was actually discarded.
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

/// Closed set of force-persistence latency stages (#613). Each member is a
/// constant chosen by the code, never anything derived from user data, and the
/// captured value is always a plain millisecond duration — nothing else rides
/// along. A message built from these goes through `beforeSend`'s scrub like
/// every other event; the closed set is the first line of defense.
const FORCE_LATENCY_STAGES = new Set([
  "rep.persist",
  "rep.insert",
  "session.predict",
  "session.insert",
  "realtime.recv",
  "realtime.refetch",
]);

/// Throttle: at most one event per stage per window. The per-rep stages fire on
/// every rep of a guided protocol — dozens of events in minutes — and the
/// point is to confirm the end-to-end latency shape (is the Finish path
/// network-free now?), not to count reps. One sample per stage per minute keeps
/// the volume bounded while still catching a regression within ~a minute.
const FORCE_LATENCY_INTERVAL_MS = 60_000;
const lastForceLatencyAt: Partial<Record<string, number>> = {};

/// #613: report the duration of one force-persistence stage. Inert without a
/// build-time DSN (like everything in this module) and gated on a closed stage
/// set, so a typo'd stage is dropped rather than sent.
export function captureForceLatency(stage: string, ms: number): void {
  if (!started || !FORCE_LATENCY_STAGES.has(stage)) return;
  const now = Date.now();
  const last = lastForceLatencyAt[stage];
  if (last !== undefined && now - last < FORCE_LATENCY_INTERVAL_MS) return;
  lastForceLatencyAt[stage] = now;
  Sentry.captureMessage(
    `force-latency: ${stage}=${Math.round(Math.max(0, ms))}ms`,
    "info",
  );
}

const HANDLED_OPERATIONS = {
  "training-data.load": { dedupeForLaunch: true },
  "session.insert": { dedupeForLaunch: false },
  "session.update": { dedupeForLaunch: false },
  "session.delete": { dedupeForLaunch: false },
  "session.restore": { dedupeForLaunch: false },
  "session.purge": { dedupeForLaunch: false },
  "workout.insert": { dedupeForLaunch: false },
  // #534: a persistently broken native listener registration would
  // otherwise re-report on every foreground/auth event for the rest of the
  // launch with no new information — dedupe it like a load failure.
  "health.readiness-listener": { dedupeForLaunch: true },
} as const;

export type HandledFailureOperation = keyof typeof HANDLED_OPERATIONS;
export type HandledFailureClass =
  | "permission"
  | "auth"
  | "network"
  | "constraint"
  | "schema"
  | "invariant"
  | "unknown";
export type HandledFailureOutcome =
  | "recovery-exhausted"
  | "zero-row-invariant";

const HANDLED_FAILURE_CLASSES = new Set<HandledFailureClass>([
  "permission",
  "auth",
  "network",
  "constraint",
  "schema",
  "invariant",
  "unknown",
]);
const HANDLED_FAILURE_OUTCOMES = new Set<HandledFailureOutcome>([
  "recovery-exhausted",
  "zero-row-invariant",
]);

/** Belt-and-braces validation behind the entry point's closed TypeScript API. */
function scrubHandledFailureFields(event: Event): void {
  const tags = event.tags;
  if (tags) {
    if (
      tags.operation !== undefined &&
      (typeof tags.operation !== "string" ||
        !Object.hasOwn(HANDLED_OPERATIONS, tags.operation))
    ) {
      delete tags.operation;
    }
    if (
      tags.failure_class !== undefined &&
      (typeof tags.failure_class !== "string" ||
        !HANDLED_FAILURE_CLASSES.has(tags.failure_class as HandledFailureClass))
    ) {
      delete tags.failure_class;
    }
    if (
      tags.outcome !== undefined &&
      (typeof tags.outcome !== "string" ||
        !HANDLED_FAILURE_OUTCOMES.has(tags.outcome as HandledFailureOutcome))
    ) {
      delete tags.outcome;
    }
    if (Object.keys(tags).length === 0) event.tags = undefined;
  }

  const extra = event.extra;
  if (!extra) return;
  if (
    extra.retry_attempts !== undefined &&
    (typeof extra.retry_attempts !== "number" ||
      !Number.isInteger(extra.retry_attempts) ||
      extra.retry_attempts <= 0)
  ) {
    delete extra.retry_attempts;
  }
  if (extra.automatic !== undefined && typeof extra.automatic !== "boolean") {
    delete extra.automatic;
  }
  if (extra.affected_rows !== undefined && extra.affected_rows !== 0) {
    delete extra.affected_rows;
  }
  if (
    extra.status !== undefined &&
    (typeof extra.status !== "number" ||
      !Number.isInteger(extra.status) ||
      extra.status < 400 ||
      extra.status > 599)
  ) {
    delete extra.status;
  }
  if (Object.keys(extra).length === 0) event.extra = undefined;
}

export interface HandledFailureDetail {
  retryAttempts?: number;
  automatic?: boolean;
  /** True only when the failed recording is durably queued for retry. */
  retainedOffline?: boolean;
}

type ErrorFacts = {
  code?: string;
  message?: string;
  name?: string;
  status?: number;
};

function errorFacts(error: unknown): ErrorFacts {
  if ((typeof error !== "object" && typeof error !== "function") || error === null) {
    return {};
  }
  const value = error as Record<string, unknown>;
  const statusValue = value.status ?? value.statusCode;
  return {
    ...(typeof value.code === "string" ? { code: value.code } : {}),
    ...(typeof value.message === "string" ? { message: value.message } : {}),
    ...(typeof value.name === "string" ? { name: value.name } : {}),
    ...(typeof statusValue === "number" &&
    Number.isInteger(statusValue) &&
    statusValue >= 400 &&
    statusValue <= 599
      ? { status: statusValue }
      : {}),
  };
}

/**
 * Classify locally from the database/client failure. The raw object and all
 * of its strings are discarded; only this closed result can cross the Sentry
 * boundary.
 */
export function classifyHandledFailure(error: unknown): HandledFailureClass {
  if (isZeroRowMutationError(error)) return "invariant";
  const { code = "", message = "", name = "", status } = errorFacts(error);
  const upperCode = code.toUpperCase();

  if (
    upperCode === "42501" ||
    status === 403 ||
    /\b(row[- ]level security|rls|permission denied|policy)\b/i.test(message)
  ) {
    return "permission";
  }
  if (
    status === 401 ||
    /^(PGRST30[123]|BAD_JWT|INVALID_JWT|JWT_EXPIRED|SESSION_NOT_FOUND)$/.test(
      upperCode,
    ) ||
    /\b(jwt|access token|authentication|not authenticated)\b/i.test(message)
  ) {
    return "auth";
  }
  if (
    name === "AbortError" ||
    /^(ECONNRESET|ECONNREFUSED|ENETUNREACH|ETIMEDOUT|NETWORK_ERROR)$/.test(
      upperCode,
    ) ||
    /\b(failed to fetch|network request failed|networkerror|timed out|offline)\b/i.test(
      message,
    )
  ) {
    return "network";
  }
  if (/^23[A-Z0-9]{3}$/.test(upperCode)) return "constraint";
  if (
    /^(42P01|42703|PGRST20[024])$/.test(upperCode) ||
    /\b(schema cache|column .* does not exist|relation .* does not exist)\b/i.test(
      message,
    )
  ) {
    return "schema";
  }
  return "unknown";
}

const handledFailureDedupe = new Set<HandledFailureOperation>();

function isExpectedHandledFailure(
  error: unknown,
  failureClass: HandledFailureClass,
  detail: HandledFailureDetail,
): boolean {
  if (detail.retainedOffline === true) return true;
  const { code = "", message = "", name = "" } = errorFacts(error);
  const upperCode = code.toUpperCase();
  if (
    name === "AbortError" ||
    /^(ABORT_ERR|CANCELED|ERR_CANCELED|USER_CANCELLED)$/.test(upperCode) ||
    /\b(user (?:cancelled|canceled)|(?:cancelled|canceled) by user)\b/i.test(
      message,
    )
  ) {
    return true;
  }
  if (upperCode === "INVALID_CREDENTIALS") return true;
  if (
    /^(BLE_DISCONNECTED|DEVICE_DISCONNECTED|NOT_CONNECTED)$/.test(upperCode) ||
    name === "BleDisconnectedError"
  ) {
    return true;
  }
  return (
    failureClass === "network" &&
    typeof navigator !== "undefined" &&
    navigator.onLine === false
  );
}

/**
 * The sole entry point for selected handled operational failures (#382).
 *
 * Call only after retry, rollback, or another recovery path has finished and
 * the operation is still failed. `operation`, `failure_class`, and `outcome`
 * are closed values selected here/by code. No raw error, database response,
 * arbitrary string, or user/training/health value is handed to Sentry.
 */
export function captureHandledOperationalFailure(
  operation: HandledFailureOperation,
  error: unknown,
  detail: HandledFailureDetail = {},
  capture: typeof Sentry.captureMessage = Sentry.captureMessage,
): string | null {
  if (!started || !Object.hasOwn(HANDLED_OPERATIONS, operation)) return null;
  const config = HANDLED_OPERATIONS[operation];
  if (config.dedupeForLaunch && handledFailureDedupe.has(operation)) return null;

  const failureClass = classifyHandledFailure(error);
  if (isExpectedHandledFailure(error, failureClass, detail)) return null;
  const zeroRows = isZeroRowMutationError(error);
  const outcome: HandledFailureOutcome = zeroRows
    ? "zero-row-invariant"
    : "recovery-exhausted";
  const { status } = errorFacts(error);
  const extra: Record<string, number | boolean> = {};
  if (
    typeof detail.retryAttempts === "number" &&
    Number.isInteger(detail.retryAttempts) &&
    detail.retryAttempts > 0
  ) {
    extra.retry_attempts = detail.retryAttempts;
  }
  if (typeof detail.automatic === "boolean") extra.automatic = detail.automatic;
  if (zeroRows) extra.affected_rows = 0;
  if (status !== undefined) extra.status = status;

  // Set before capture so a transport/client exception cannot turn a single
  // load outage into repeated events during the same launch.
  if (config.dedupeForLaunch) handledFailureDedupe.add(operation);
  return capture("handled operational failure", {
    level: "error",
    tags: {
      operation,
      failure_class: failureClass,
      outcome,
    },
    fingerprint: ["handled-operational-failure", operation, failureClass],
    ...(Object.keys(extra).length ? { extra } : {}),
  });
}

/** Report an uncaught render error from the ErrorBoundary. */
export function captureAppError(error: unknown, componentStack?: string): void {
  if (!started) return;
  Sentry.captureException(
    error,
    componentStack ? { contexts: { react: { componentStack } } } : undefined,
  );
}
