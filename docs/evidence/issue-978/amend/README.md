# issue-978 amendment evidence — PhaseTransitionReplayAppTests (third site)

Scope amendment (owner, 2026-09-20): also harden the remaining bounded/unwaited
window behind the assertions at :260/:261/:263 of testLostSettingsHalfIsCompletedFromTheServerState.
The :517-524 budget #970 already hardened is untouched.

Base for the amendment: head 1be6fb7b (re-prepped lane head, staging merged, test files
byte-identical to c8c58520's).

## What changed (49 added lines, 0 deleted)
- New `waitForReplayPublished(model,server,phase,startedOn)` helper (the #970 waitUntil
  shape): after `retryAllQueuedWrites()` returns, it deadline-bound waits (60 s) for the
  PUBLISHED end state — server settings row = target phase/date, exactly one open period,
  pendingCacheWriteCount == 0, queuedWriteCount == 0. On expiry it prints the server's
  settings row, open periods, both counters, the model's currentPhase and the durable
  queue state.
- One call inserted in testLostSettingsHalfIsCompletedFromTheServerState between the
  existing `waitForQueueCount(relaunched, 0)` and the :260-:263 assertions.
- NO assertion values or messages changed; nothing skipped/retried; the :517-524
  #970 treatment is untouched.

## Contended-run validity under the host-hygiene intervention
The conductor killed 24 orphaned burners (from the v1 harness) at ~20:41 +07 and ordered
re-measurement with a bounded, self-terminating harness. Accordingly:
- contend2.sh v5: burners spawned by the parent, pids recorded in a per-invocation file,
  a disowned watchdog hard-kills them at the deadline (parent exit/-9-proof, machine-checked
  WATCHDOG_ORPHAN_PROOF=PASS; STOP_PATH_PROOF=PASS).
- PRE-FIX contended rows (phase-pre2-c-1..2) were taken before harness validation and are
  DISCARDED from the evidence set (kept for lineage only).
- HEAD contended rows (phase-head5-c-1..6): per-run ledger lines record
  burners_recorded=8 alive_before=8 AND alive_after=8 — the contention demonstrably
  spanned each measured run. These are the N=6 contended evidence.

## Runs (all `-only-testing:SendmeterNativeTests/PhaseTransitionReplayAppTests`,
CI-shape xcodebuild + explicit -derivedDataPath; raw exits also in ../run-ledger.txt)

Quiet (hardened head, clean container per run, N=6):
- phase-head-q-1..6.log.gz — 6/6 exit 0, 9/9 tests, 0.545-2.100 s suite.

Contended (hardened head, 8 burners verified alive per run, N=6):
- phase-head5-c-1..6.log.gz — 6/6 exit 0, 9/9 tests, 0.721-1.188 s suite.

Pre-fix baseline (unhardened window, same head content BEFORE the amendment commit):
- phase-base2-1.log.gz / phase-pre2-c-1.log.gz — exit 0, 9/9 pass (quiet; and under
  contention): the window race needs hosted-runner contention to bite locally; locally it
  manifests only intermittently under load (the PR #983 first-run 3-failure leg), so the
  base rows here are labelled NOT-REPRODUCED-LOCALLY rather than claimed as local fails.

## RED proof (hardened wait still fails when the behaviour genuinely does not happen)
- red-probe2-splice.diff — applied ONLY in scratch worktree /tmp/impl978-probe2 at
  1be6fb7b: the fake server's POST /user_settings becomes a silent NO-OP, so the
  completeness step (the settings half) genuinely never lands server-side. The periods
  half, the durable queue, the retry pass all run the real boundary.
- red-probe2.log.gz + red-probe2-keylines.txt — the hardened wait TIMED OUT:
  `timed out after 60.000165958000004 seconds waiting for the replayed transition to be
  published: settings=strength@2026-09-21, ...; observed serverSettings=capacity@2026-01-05,
  openPeriods(1)=[strength@2026-09-21], pendingCacheWriteCount=0, queuedWriteCount=0, ...`
  and then the ORIGINAL assertions (:269/:270) still failed (capacity != strength) —
  exit 65. The diagnostic distinguishes "settings half lost" from slowness, exactly as
  required.

## Gates
- gate2-just-fast.log.gz — `just fast` exit 0 (~2132 test cases, 0 failures).
- gate2-slop.log.gz — `just slop` exit 0.
