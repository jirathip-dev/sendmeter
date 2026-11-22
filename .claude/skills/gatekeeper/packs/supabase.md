# The supabase pack

the migration files' names, order and policy rule, and pgTAP on a local stack (CI only on a lane's host)

## supabase/migrations

static, no database: each file under supabase/migrations is <14-digit UTC timestamp>_<name>.sql with a real time and a unique version; on a pull request each new file is newer than the base's newest and its policies call (select auth.uid()), never bare auth.uid()

- fix: rename the file with a new timestamp newer than every migration on the base, or wrap auth.uid() as (select auth.uid()); never edit a migration the base already has
- budget: 10s
- cached: no, reads the base
- rerun: `./.gatekeeper/run check --gate supabase/migrations`
- what a failure looks like: [supabase-migrations](../examples/supabase-migrations.md)

## supabase/pgtap

a local Supabase stack, a reset from supabase/migrations, then every file under supabase/tests/ by pgTAP (found by glob, no per-file step); CI only on a lane's host, it needs containers

- fix: fix the migration or the test the pgTAP output names; a test file anywhere under supabase/tests/ runs
- budget: 300s
- cached: yes
- rerun: `./.gatekeeper/run check --gate supabase/pgtap`
- what a failure looks like: [supabase-pgtap](../examples/supabase-pgtap.md)
