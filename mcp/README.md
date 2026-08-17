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

**The numbers never depend on the `days`/`weeks` you pass.** The ACWR ratio is
defined by the full 90-day EWMA window, and the weekly buckets by `weeks*7`
days — the server always fetches at least those, so a short display window can
never fabricate zero-load days or a false injury warning (issue #644 review
F3/F4, pinned by `test/load.test.ts`'s dead-constant-700 regression).

## Setup

Prereqs: Node 20+ (`mise` in this repo provides it).

```bash
cd mcp
npm install
npm run build
```

The server resolves your session in this order:

1. **`SENDMETER_MCP_TOKEN`** — a ready-made access token (e.g. from the web
   app's devtools, or a token minted for you). Never persisted, held in memory
   only. **Recommended for non-interactive setups** — no account password ever
   sits in a config file.
2. **`SENDMETER_MCP_EMAIL` + `SENDMETER_MCP_PASSWORD`** — non-interactive
   password sign-in against the hosted project
   (`https://zznsqmcewtzlnfoiefkk.supabase.co`). Prefer the token path for a
   long-lived MCP client config; a plaintext account password in a config file
   is exactly the standing-credential this server is designed to avoid.
3. **Interactive prompt** — only when run in a TTY *and* no credentials are
   configured. MCP clients talk to the server over stdin/stdout, so the prompt
   is never offered on the serve path; a client with no credentials sees the
   server exit with a clear instruction instead.

**The server never mints or persists a refresh token.** Repo invariant: only
the web app's supabase-js holds refresh tokens. This server keeps a single
access token in memory and, when PostgREST rejects it (HTTP 401), re-signs-in
with the configured credentials automatically — or, with none available,
returns a structured error telling you to re-authenticate. There is no session
file, nothing written to disk, nothing to leak. (Issue #644 review F6/F5.)

Environment overrides (for the local stack / other projects):

| Env | Default |
|---|---|
| `SENDMETER_MCP_URL` | `https://zznsqmcewtzlnfoiefkk.supabase.co` |
| `SENDMETER_MCP_ANON_KEY` | the hosted publishable key |

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
  password sign-in). PostgREST + RLS is the boundary: every query carries
  `Authorization: Bearer <user access token>` and the server holds no other
  credential. Pinned structurally by `test/invariants.test.ts` (the string
  `service_role` must not exist in `src/`) and behaviourally by
  `test/transport.test.ts` (every request is a GET carrying the user's Bearer
  token).
- **Zero writes.** No insert/update/delete/upsert/rpc call sites exist anywhere
  in `src/` (`test/invariants.test.ts` scans the source recursively).
- **No refresh token.** `test/invariants.test.ts` pins that the words
  `refreshToken` / `refresh_token` / `refreshSession` never appear in `src/` —
  the same structural shape as the app's `nativeAuthInvariants.test.ts`.
- **No telemetry, no analytics.** The only network the server ever makes is to
  the Supabase project (PostgREST + the auth token endpoint).
- The access token lives in memory only; nothing is ever written to disk.

## Tests

```bash
npm test              # vitest — 81 tests, never touches the network
npm run typecheck     # tsc --noEmit (covers src/ AND test/)
```

What's covered: the six tools against a mock store (validation, aggregation,
peaks, trend/recovery signals); the transport against a recorded `fetch`
(token header, GET-only, 401 → re-auth → retry-once, error surfacing); the
auth bootstrap (precedence, password grant, token-provider rotation); the
ACWR/EWMA math **against the web app's own implementation** as an oracle,
including the dead-constant-700 window-independence regression (days=7/14/30
all read ~1.00); a full JSON-RPC round trip over the SDK's in-memory
transport; and the structural no-write / no-key / no-refresh-token
invariants.

## What needs a real user session

The unit suite mocks the PostgREST transport. End-to-end verification
(signing in against a real Supabase project, answering prompts with the
authenticated user's live rows, and the second-user-gets-empty-results RLS
check) is done against the **local stack** — point `SENDMETER_MCP_URL` at it,
sign in with `dev@sendmeter.test` / `devpassword`, and run
`scripts/e2e.mjs` (usage documented in its header). A recorded transcript,
including the second-user RLS check and the expiry behaviour, lives in
`../docs/mcp-e2e-verification.md`.
