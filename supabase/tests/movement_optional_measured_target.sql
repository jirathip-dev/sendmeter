-- #508-510 movement recording shape contract. Everything rolls back.
begin;

select plan(3);

select lives_ok($$
  insert into public.tindeq_recordings (
    id, user_id, duration_ms, peak_kg, avg_kg, sample_count, samples,
    protocol_run_id, set_no, source, protocol_mode,
    cadence_out_s, cadence_return_s, cadence_markers, set_metrics,
    capacity_evidence, completed_reps, completion_status
  ) values (
    '50800000-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    40000, 14, 12, 2, '[[0,10],[40000,14]]'::jsonb,
    '50800000-0000-0000-0000-000000000010', 1, 'dynamometer', 'reverse_action',
    3, 1,
    '[{"tMs":0,"rep":1,"direction":"out"}]'::jsonb,
    '{"meanKg":12,"coefficientVariationPct":4,"inTargetPct":null,"timeUnderTensionMs":40000,"driftPct":-2,"cadenceAdherencePct":100}'::jsonb,
    false, 10, 'complete'
  )
$$, 'measured resisted movement may omit a force target while retaining trace and metrics');

select lives_ok($$
  insert into public.tindeq_recordings (
    id, user_id, duration_ms, peak_kg, avg_kg, sample_count, samples,
    protocol_run_id, set_no, source, planned_duration_ms, actual_duration_ms,
    protocol_mode, cadence_out_s, cadence_return_s, cadence_markers,
    capacity_evidence, completed_reps, completion_status
  ) values (
    '50800000-0000-0000-0000-000000000002',
    '11111111-1111-1111-1111-111111111111',
    40000, null, null, 0, '[]'::jsonb,
    '50800000-0000-0000-0000-000000000010', 2, 'manual', 40000, 40000,
    'reverse_action', 3, 1,
    '[{"tMs":0,"rep":1,"direction":"out"}]'::jsonb,
    false, 10, 'complete'
  )
$$, 'cadence-only resisted movement remains an honest target-free manual row');

select throws_ok($$
  insert into public.tindeq_recordings (
    id, user_id, duration_ms, peak_kg, avg_kg, sample_count, samples,
    protocol_run_id, set_no, source, protocol_mode,
    cadence_out_s, cadence_return_s, cadence_markers,
    capacity_evidence, completed_reps, completion_status
  ) values (
    '50800000-0000-0000-0000-000000000003',
    '11111111-1111-1111-1111-111111111111',
    40000, 14, 12, 2, '[[0,10],[40000,14]]'::jsonb,
    '50800000-0000-0000-0000-000000000010', 3, 'dynamometer', 'reverse_action',
    3, 1, '[]'::jsonb,
    false, 10, 'complete'
  )
$$, '23514', null::text,
  'measured resisted movement cannot discard its execution metrics');

select * from finish();
rollback;
