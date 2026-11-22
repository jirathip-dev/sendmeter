# supabase/pgtap: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## failing-test

Writes `supabase/tests/notes.test.sql`:

```
begin;
create extension if not exists pgtap with schema extensions;
select plan(1);
select has_table('public', 'missing', 'public.missing exists');
select * from finish();
rollback;
```

The gate fails and its log prints `Result: FAIL`.

Fix: fix the migration or the test the pgTAP output names; a test file anywhere under supabase/tests/ runs. Rerun: `./.gatekeeper/run check --gate supabase/pgtap`

## test-file-not-run

Writes `supabase/tests/nested/deep/extra.test.sql`:

```
begin;
create extension if not exists pgtap with schema extensions;
select plan(1);
select has_column('public', 'notes', 'title', 'public.notes has a title');
select * from finish();
rollback;
```

The gate fails and its log prints `nested/deep/extra.test.sql`.

Fix: fix the migration or the test the pgTAP output names; a test file anywhere under supabase/tests/ runs. Rerun: `./.gatekeeper/run check --gate supabase/pgtap`
