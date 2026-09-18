# Error monitoring (Sentry, web layer) — issue #227

> **Superseded — kept for reference (#857).** This document describes the
> WebView/React layer that was retired with the web surface
> (`docs/architecture/857-removal-inventory.md`). The shipped app is native and
> deliberately omits the web error-monitoring SDK — no Diagnostics data type is
> declared (see `docs/app-store-checklist.md` → App Privacy answers). The
> commands below (root npm scripts, Vite config, Vercel env) no longer exist in
> this repo; nothing here is a current instruction.

## What it is for

The web layer reports JS exceptions we otherwise cannot see: a crash on a phone
we don't hold, a React render failure, or an unhandled rejection in background
work. It also reports a deliberately small set of handled operational failures
after their recovery path is exhausted (issue #382), described below.

**What it still does not catch:** silent auth-state transitions such as the #202
overnight logout. Auth-js removes the session and emits `SIGNED_OUT`, with no
exception or rejection. That is what the bounded on-device ring in
`src/lib/authDiagnostics.ts` exists for, and this does not replace it. Don't
expect Sentry to explain a "logged out again" report.

Native crash reporting (Sentry Cocoa) is **out of scope** — this is the WebView
JS layer only. A Swift crash in the watch app or a plugin still shows up only in
App Store Connect → Crashes.

## Handled operational failures

`captureHandledOperationalFailure` is the sole entry point. Callers choose an
operation from a closed TypeScript union; failure class and outcome are derived
locally as closed values. The raw Supabase/client error is inspected only on the
device and is never passed to Sentry. Events have a constant message and a
stable fingerprint of `operation + failure class`, so one outage groups into
one issue.

Monitored after final recovery:

- the initial sessions/settings/phase-period load, only after all three attempts
  fail and at most once per app launch;
- session insert/update/delete/restore/purge failures after UI rollback or the
  final caught mutation failure;
- phone-workout inserts and automatic routine/Tindeq session logs whose failure
  leaves completed work absent from History;
- a mutation scoped to one expected row that returns success with zero rows.
  The repository requests the affected row with `maybeSingle()` and turns null
  into `ZeroRowMutationError`, rather than silently accepting an RLS-filtered
  update/delete.

Deliberately excluded:

- either of the first two training-data load failures when a later retry works;
- network failures while the browser reports that the device is offline;
- ordinary token expiry that recovers, invalid-credential responses from sign
  in, and user-cancelled auth/device prompts;
- expected BLE disconnects;
- Tindeq recording insert failures when the recording is safely retained in the
  offline queue (the existing data-loss signal remains responsible only when
  durable local retention itself fails);
- legitimate no-row lookups implemented with `maybeSingle()` (live workout,
  optional workout detail, and similar reads). Only mutation helpers use the
  zero-row invariant.

Classification covers permission/RLS, auth, network, constraint, schema,
zero-row invariant, and unknown failures. Sentry receives only the controlled
classification, operation, outcome, and applicable numeric/boolean facts:
retry-attempt count, automatic/manual flag, affected-row count, and a validated
HTTP status. PostgreSQL/PostgREST codes are used locally for classification but are
not sent.

## The scrub is the feature

`src/lib/monitoring.ts` builds the outgoing event from an allow-list; anything
not explicitly allowed is dropped before the transport sees it.

| Rule | Where |
|---|---|
| Identity is the Supabase auth uuid, never email/username/IP | `scrubEvent`, `setMonitoringUser` |
| Every `HealthMetric` field name (camelCase + `health_metrics` column names) drops its whole subtree; any string naming one is redacted whole (which takes the value with it) | `HEALTH_TERMS`, `scrubDeep` |
| URLs lose query string + fragment | `stripQuery` |
| `extra` / `contexts` / `tags` keep allow-listed keys only | `ALLOWED_*` |
| Handled-failure tags are closed operation/class/outcome values; details are runtime-checked numbers/booleans only | `captureHandledOperationalFailure` |
| Breadcrumbs: only `navigation` / `fetch` / `xhr` / `ui.click`, with an allow-listed `data` shape. `console` is dropped — a console line can contain anything | `scrubBreadcrumb` |
| No replay, no tracing, and every `dataCollection` switch off — no inferred user, cookies, headers, bodies, query params, or stack-frame locals (that one defaults to *on*, and a local could be a whole health record) | `initMonitoring` |
| `BrowserSession` integration disabled — session envelopes bypass `beforeSend`, so dropping it means *every* outbound envelope has been scrubbed | `initMonitoring` |

`src/lib/monitoring.test.ts` builds an event carrying every `HealthMetric` value
in every place Sentry would realistically put it (state dump in `extra`, a
context block, a breadcrumb, the request query string, the exception message)
and asserts that none of the values or field names survive serialization. It
first asserts the *unscrubbed* fixture contains them all, so the test cannot
pass by being empty.

The handled-failure tests separately pass representative Supabase `message`,
`details`, `hint`, response body, session note, training values, health values,
and email into the local classifier and assert none reach the capture call.
They also pin the controlled event shape, grouping, launch deduplication,
zero-row outcome, and the same DSN-less no-op gate.

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

## The `environment` tag (#239)

Every event is tagged with the deploy it came from. **Don't use
`import.meta.env.MODE` for this** — `npm run build` is a plain `vite build`
with no `--mode`, which Vite defaults to `production`, so `MODE` reads
`production` in a Vercel preview deploy and in the TestFlight archive too. That
was the bug: preview and native errors mixed into the real user stream.

The value comes from `resolveDeployEnv` (`src/lib/deployEnv.ts`), a pure helper
`vite.config.ts` calls at build time and inlines into the bundle via `define`
as `import.meta.env.VITE_DEPLOY_ENV` (Vite only forwards `VITE_`-prefixed vars
to client code, and `VERCEL_ENV` isn't one). Precedence, pinned by
`deployEnv.test.ts`:

**`VITE_DEPLOY_ENV` (explicit override) → `VERCEL_ENV` → `"local"`.**

The override outranks `VERCEL_ENV` because Vercel always sets `VERCEL_ENV`; the
other order would make the override a no-op there. Blank/whitespace counts as
unset.

| Where it's built | Tag | Comes from |
|---|---|---|
| Vercel Production (`main`) | `production` | `VERCEL_ENV`, set by Vercel |
| Vercel Preview (`staging`, promotion PRs) | `preview` | `VERCEL_ENV`, set by Vercel |
| `vercel dev` | `development` | `VERCEL_ENV`, set by Vercel |
| TestFlight / iOS (`fastlane beta`) | `ios` | `VITE_DEPLOY_ENV=ios` exported to the lane |
| Local `npm run dev` / `npm run build` | `local` | fallback — nothing set |

Only Vercel sets its own value; the other two are a deliberate export or the
fallback. The iOS tag is worth keeping distinct even though the code is the
same bundle: a WebView-in-native runtime is a materially different context from
a browser one.

`fastlane beta` runs its own `npm run build`, so whatever shell runs the lane
must export `VITE_DEPLOY_ENV=ios` — same requirement as `VITE_SENTRY_DSN`
above, and un-set means the TestFlight build reports `local`.

## End-to-end verification

Issue #373 verified the full path on 2026-08-01 from both a preview deployment
and TestFlight. Sentry received the synthetic event with the expected
`preview`/`ios` environment, an `ios` platform tag for TestFlight, a bare auth
uuid, and a query-free `capacitor://localhost` URL. The temporary Account-sheet
diagnostic action was removed after that verification; normal monitoring stays
enabled.

The build/typecheck/lint/test gate proves the scrub and wiring but cannot prove
transport and dashboard ingestion. If the end-to-end path needs reverification,
use a temporary diagnostic in a dedicated test build rather than restoring a
permanent production control. To test Sentry's default global handlers on the
web, run
`setTimeout(() => { throw new Error("sentry-e2e-web"); }, 0)` in browser devtools
and confirm that event arrives. The release WebView remains deliberately
non-inspectable.
