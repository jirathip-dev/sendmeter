# sendmeter-mcp

A **local, per-user, read-only MCP server** for Sendmeter (issue #644). It
exposes your own Sendmeter data — Supabase Postgres, the same tables the app
writes — to any MCP-capable agent (Claude Code, Hermes, …) as six read-only
tools. It is the repo's first MCP server.

Everything is scoped by **RLS** (`auth.uid()`) to the authenticated user: the
server signs in *as you*, holds your user session, and never touches a
service-role key. There are no write paths anywhere in the server.

## Tools (all read-only)

| Tool | Inputs | Returns |
|---|---|---|
| `get_health_metrics` | `from`, `to`, `metric?` (`hrv`/`rhr`/`sleep`/`weight`) | daily series of the requested metrics |
| `get_sessions` | `from`, `to`, `discipline?` | per-day aggregates (duration, load, RPE, types) + totals + workout attempt counts |
| `get_readiness` | `days` (default 14) | daily readiness scores (0–100) + avg/min/max + low-day count |
| `get_acwr` | `days` (default 90) | acute 7d load, chronic avg, EWMA ratio + risk-zone label + current phase |
| `get_tindeq` | `recording_id?` / `session_id?` / `limit` | recording summaries (peak/avg kg, duration) + top force peaks from the sample curves |
| `analyze_training_load` | `weeks` (default 4), `days` (default 90) | weekly load trend, ACWR, readiness trend, data-grounded signal notes |

All values are read **stored** where they exist (`sessions.load`,
`health_metrics.readiness`); ACWR is derived exactly like the web app
(`src/lib/metrics.ts` — EWMA spans 7/28, mean-seeded 90-day window; the
parity is pinned by `test/load.test.ts`, which runs both implementations on
shared inputs).

## Setup

Prereqs: Node 20+ (`mise` in this repo provides it).

```bash
cd mcp
npm install
npm run build
```

The server resolves your session in this order:

1. **`SENDMETER_MCP_TOKEN`** — a ready-made access token (e.g. from the web
   app's devtools, or a token minted for you). Never persisted.
2. **Session file** `~/.sendmeter-mcp/session.json` (0600) — created by the
   flows below, refreshed automatically when near expiry.
3. **`SENDMETER_MCP_EMAIL` + `SENDMETER_MCP_PASSWORD`** — non-interactive PKCE
   sign-in against the hosted project (`https://zznsqmcewtzlnfoiefkk.supabase.co`).
4. **Interactive prompt** — when run in a TTY, you're asked for email +
   password (hidden input).

The session file stores the server's *own* refresh token, minted by its own
sign-in — it never imports the web app's or watch's refresh token (those are
single-use with reuse detection; sharing them would revoke the whole session
family). Each run with a live file just works.

Environment overrides (for the local stack / other projects):

| Env | Default |
|---|---|
| `SENDMETER_MCP_URL` | `https://zznsqmcewtzlnfoiefkk.supabase.co` |
| `SENDMETER_MCP_ANON_KEY` | the hosted publishable key |
| `SENDMETER_MCP_SESSION_FILE` | `~/.sendmeter-mcp/session.json` |

## Running

```bash
npm run mcp           # serve over stdio (the MCP default) — build first
npm run dry-run       # exercise all 6 tools against synthetic data; no network, no credentials
```

Point an MCP client at the server, e.g. Claude Code:

```json
{ "mcpServers": { "sendmeter": { "command": "node", "args": ["/path/to/sendmeter/mcp/dist/index.js"] } } }
```

Then ask: *"summarise this week's training load and recovery"* —
`analyze_training_load` + `get_readiness` answer it with data-grounded notes.

## Security model

- **User session only.** The server authenticates as the user (user token or
  PKCE password sign-in). PostgREST + RLS is the boundary: every query
  carries `Authorization: Bearer <user access token>` and the server holds no
  other credential. Pinned structurally by `test/invariants.test.ts` (the
  string `service_role` must not exist in `src/`) and behaviourally by
  `test/transport.test.ts` (every request is a GET carrying the user's
  Bearer token).
- **Zero writes.** No insert/update/delete/upsert/rpc call sites exist in the
  data layer (`test/invariants.test.ts` scans the source).
- **No telemetry, no analytics.** The only network the server ever makes is
  to the Supabase project (PostgREST + the auth token endpoint).
- The session file is chmod 0600; tokens are never logged.

## Tests

```bash
npm test              # vitest — 61 tests, never touches the network
npm run typecheck     # tsc --noEmit
```

What's covered: the six tools against a mock store (validation, aggregation,
peaks, trend/recovery signals); the transport against a recorded `fetch`
(token header, GET-only, error surfacing); the auth bootstrap (precedence,
refresh, dead-credential cleanup, file perms); the ACWR/EWMA math **against
the web app's own implementation** as an oracle; a full JSON-RPC round trip
over the SDK's in-memory transport; and the structural no-write / no-key
invariants.

## What needs a real user session

The unit suite mocks the PostgREST transport. End-to-end verification
(signing in against a real Supabase project, answering prompts with the
authenticated user's live rows, and the second-user-gets-empty-results RLS
check) requires a real session — run `npm run mcp` with a token or
credentials, or point `SENDMETER_MCP_URL` at the local stack and sign in with
`dev@sendmeter.test` / `devpassword`. `scripts/e2e.mjs` is a manual harness
that drives the real server over stdio and exercises all six tools (usage
documented in its header).
