# Error monitoring (Sentry, web layer) — issue #227

## What it is for

Exactly one class of bug: the one we currently cannot see at all. A JS exception
on a phone we don't hold, a React render crash that leaves a white screen, an
unhandled rejection in a background sync. Before this, those were invisible
unless the user described them.

**What it does not catch:** anything that fails *silently*. The #202 overnight
logout throws nothing — auth-js removes the session and emits `SIGNED_OUT`, no
exception, no rejection. That is what `auth_events` / `src/lib/authDiagnostics.ts`
exist for, and this does not replace them. Don't expect Sentry to explain a
"logged out again" report.

Native crash reporting (Sentry Cocoa) is **out of scope** — this is the WebView
JS layer only. A Swift crash in the watch app or a plugin still shows up only in
App Store Connect → Crashes.

## The scrub is the feature

`src/lib/monitoring.ts` builds the outgoing event from an allow-list; anything
not explicitly allowed is dropped before the transport sees it.

| Rule | Where |
|---|---|
| Identity is the Supabase auth uuid, never email/username/IP | `scrubEvent`, `setMonitoringUser` |
| Every `HealthMetric` field name (camelCase + `health_metrics` column names) drops its whole subtree; any string naming one is redacted whole (which takes the value with it) | `HEALTH_TERMS`, `scrubDeep` |
| URLs lose query string + fragment | `stripQuery` |
| `extra` / `contexts` / `tags` keep allow-listed keys only | `ALLOWED_*` |
| Breadcrumbs: only `navigation` / `fetch` / `xhr` / `ui.click`, with an allow-listed `data` shape. `console` is dropped — a console line can contain anything | `scrubBreadcrumb` |
| No replay, no tracing, and every `dataCollection` switch off — no inferred user, cookies, headers, bodies, query params, or stack-frame locals (that one defaults to *on*, and a local could be a whole health record) | `initMonitoring` |
| `BrowserSession` integration disabled — session envelopes bypass `beforeSend`, so dropping it means *every* outbound envelope has been scrubbed | `initMonitoring` |

`src/lib/monitoring.test.ts` builds an event carrying every `HealthMetric` value
in every place Sentry would realistically put it (state dump in `extra`, a
context block, a breadcrumb, the request query string, the exception message)
and asserts that none of the values or field names survive serialization. It
first asserts the *unscrubbed* fixture contains them all, so the test cannot
pass by being empty.

When adding a field to `HealthMetric`, add its name (both spellings) to
`HEALTH_TERMS` and to the test's field list.

## The DSN

`import.meta.env.VITE_SENTRY_DSN`, build-time only, **never committed**. Absent
=> `initMonitoring()` returns immediately and the SDK is dead-code-eliminated
from the bundle (measured: +1.5 kB raw / +0.4 kB gzip without a DSN, +87 kB raw
/ +29 kB gzip with one). So dev, `npm test`, and any DSN-less build send nothing
at all.

It has to be set in each environment that builds the web bundle:

- **Vercel** — project settings → Environment Variables, Production and Preview.
- **TestFlight / iOS** — the archive bundles `ios/App/App/public`, which
  `fastlane beta` produces with its own `npm run build`. Whatever shell runs the
  lane needs `VITE_SENTRY_DSN` in its environment, or the shipped app has no
  monitoring. **Not wired up yet** — the `testflight` GitHub environment needs
  the secret added and exported to the lane.

## Verification (device / TestFlight — not doable headlessly)

The build/typecheck/lint/test gate proves the scrub and the wiring; it cannot
prove an event reaches the dashboard. Do this once on a real build:

1. Create the Sentry project, put its DSN in Vercel (Preview) and confirm a
   preview deploy's bundle contains the SDK.
2. Trigger an **uncaught render error** (temporarily throw in a component) —
   confirm the app shows the ErrorBoundary fallback, "Try again" recovers, and
   the issue appears in Sentry.
3. Trigger an **unhandled rejection** (`Promise.reject(new Error("x"))` from the
   console / a temporary button) — confirm it appears via the global handler.
4. On each, open the event in Sentry and read it end to end: user is a bare
   uuid, no email, no query strings, no `extra`/`contexts` beyond the allow-list,
   and **no health numbers anywhere**.
5. Repeat 2–4 from a TestFlight build once the lane carries the DSN, since the
   native WebView is a different runtime from the browser.
