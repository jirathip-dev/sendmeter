# sendmeter-mcp e2e verification (issue #644)

Recorded 2026-08-18 against the **local Supabase stack only** (`npx supabase
start` — never the hosted project). Verifies acceptance criteria 1, 2 and 4 of
issue #644 end-to-end through the real stdio server, exactly as an MCP client
would drive it (`scripts/e2e.mjs` does a full initialize → listTools →
callTool session).

## Setup

```bash
npx supabase start            # local stack; seed.sql applies dev@sendmeter.test
cd mcp && npm run build
```

Local publishable anon key and project URL come from `supabase status`.

## Criterion 1 — six tools served against the real schema (dev user)

```bash
MCP_URL=http://127.0.0.1:54321 MCP_ANON=<local anon key> \
  MCP_EMAIL=dev@sendmeter.test MCP_PASSWORD=devpassword \
  LABEL=login node scripts/e2e.mjs
```

```
[login] tools served: get_health_metrics, get_sessions, get_readiness, get_acwr, get_tindeq, analyze_training_load
[login] get_health_metrics -> ok days=14 rows=14 sample={"date":"2026-08-01","hrv_sdnn_ms":64.1}
[login] get_sessions -> ok sessions=32 load=15277 days=26
[login] get_readiness -> ok latest={"date":"2026-08-14","readiness":68} avg=73.4
[login] get_acwr -> ok acwr=0.65 (Under-training) phase=strength
[login] get_tindeq -> ok recordings=1 best=42.75 peaks=1
[login] analyze_training_load -> ok trend=decreasing acwr=0.65 notes=1
[login] server stderr: sendmeter-mcp: serving 6 read-only tools for dev@sendmeter.test @ http://127.0.0.1:54321
```

## Criterion 2 — a second user gets empty results (RLS)

Sign up a throwaway local user, then run the harness as them:

```bash
curl -s -X POST "http://127.0.0.1:54321/auth/v1/signup" \
  -H "Content-Type: application/json" -H "apikey: <local anon key>" \
  -d '{"email":"second@user.test","password":"secondpassword"}'

MCP_URL=http://127.0.0.1:54321 MCP_ANON=<local anon key> \
  MCP_EMAIL=second@user.test MCP_PASSWORD=secondpassword \
  LABEL=second-user node scripts/e2e.mjs
```

```
[second-user] tools served: get_health_metrics, get_sessions, get_readiness, get_acwr, get_tindeq, analyze_training_load
[second-user] get_health_metrics -> ok days=0 rows=0 sample=null
[second-user] get_sessions -> ok sessions=0 load=0 days=0
[second-user] get_readiness -> ok latest=null avg=null
[second-user] get_acwr -> ok acwr=null (No data) phase=null
[second-user] get_tindeq -> ok recordings=0 best=null peaks=0
[second-user] analyze_training_load -> ok trend=insufficient_data acwr=null notes=1
[second-user] server stderr: sendmeter-mcp: serving 6 read-only tools for second@user.test @ http://127.0.0.1:54321
```

Every tool answers `0 rows` / `No data` — nothing from the dev user's rows
leaks across the RLS boundary.

## Expiry behaviour (issue #644 review F5) — verified live

1. **Valid env email/password + an expired/garbage `SENDMETER_MCP_TOKEN`**:
   the first request 401s, the server re-signs-in with the env credentials and
   every tool answers with live rows. No restart needed.
2. **Expired token, no credentials**: every tool returns a structured
   `isError` result with a clear re-auth instruction — never a crash, never a
   silent wrong answer:

```
[expired-no-creds] get_health_metrics -> ERROR error: access token expired (token-authenticated user). Set a fresh SENDMETER_MCP_TOKEN or SENDMETER_MCP_EMAIL/SENDMETER_MCP_PASSWORD and restart.
```

The unit suite pins the same paths offline (`test/transport.test.ts`,
`test/auth.test.ts`); these transcripts prove the real stdio server honours
them.

## Reproduce

All of the above is rerunnable on a clean local stack — `supabase db reset`
re-applies `seed.sql`, the second user is a throwaway local row, and no hosted
project state is ever touched.
