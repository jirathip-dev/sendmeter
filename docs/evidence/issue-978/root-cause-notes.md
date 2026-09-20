# issue-978 root-cause work notes (lane, 2026-09-20)

## What the failed base run actually left behind (raw evidence)

After base-1-guided (FAILED at GuidedProtocolCompletionTests.swift:88/:98, `1 != 2`),
the simulator app container held:

- cache: `9400…0940|recordings|4`, `9400…0940|sessions|1`  (the fixed test account)
- queue (pending-writes.json, 5 items, all for 9400…0940):
  0. recording group=1F976D55 attempts=1      <- protocol 1, uploaded+acked
  1. recording group=1F976D55 attempts=1      <- protocol 2, uploaded+acked
  2. session   group=1F976D55 attempts=0 note="2 recordings · FDP"   <- THE END
  3. recording group=BB823C41 attempts=0      <- protocol 3 save, NEVER UPLOADED
  4. recording group=3022ED9E attempts=1      <- a LATER run's save

Read: the test's protocol-3 rep was enqueued and never retried; the finished
#941 run (items 0-2) is COMPLETE and CORRECT. The failure was not "the third
save never happened" — it was a publication/ack race on rows 0-1.

## The two independent interleavings that produce `1 != 2`

(1) LOST ACK — replaceRecording(saved) after an overlay reset.
  saveForceSummary: cacheUpsertLocal (optimistic, pending=1) -> insertPendingRecording
  -> mergeRecordings -> enqueueAndUpload -> DETACHED Task{ upload(item) } (AppModel.swift:7845)
  upload: repository.insertRecording (PostgREST POST, StubURLProtocol replies from a
  thread-pool thread) -> publishIfCurrent { removePendingRecording; replaceRecording(saved) }
  Meanwhile AppModel init Task (AppModel.swift:927) runs
  CachePreparation.preparedCache -> hydrateCachedWorkspace (AppModel.swift:2120):
    recordings = snapshot.recordings          (line 2145, REPLACES the array)
    pendingRecordings = PendingRecordingOverlay()  (line 2160, RESETS the overlay
        BEFORE rebuild — a removePendingRecording landing between = silent no-op)
  When the replace/ack interleaves the hydration, the group's rows vanish from
  the published array while remaining durable (queue + cache). No retry republishes
  them (items are marked attempted; drain skips them). Assertion at :88/:98 then
  reads 1 row where 2 are durable — the OLD test had NO wait there at all.

(2) SHARED FIXED ACCOUNT + SHARED ON-DISK STATE across repetitions.
  makeSession() hardcodes userID 94000000-…-0940 (GuidedProtocolCompletionTests.swift:379).
  The suite shares ONE app container on the sim (no per-test uninstall in CI or the
  old loops). Every repetition leaves 5+ queue items and 4+ cache rows for the SAME
  account id. The next repetition's AppModel init opens that SAME cache+queue and its
  hydration republishes the PREVIOUS run's 4 group rows from disk. The run then asserts
  over a mixture of two runs' state; `tindeqEntryCount == 0` / `entries.count == 1`
  flip on which rows survived the second hydrate. This is the "moving assertion
  lines" signature in the issue, and why focus runs alone also failed.

  PhaseTransitionReplayAppTests solved exactly this with `private let userID = UUID()`
  ("a shared user id would leak one test's rows into the next") — but its scope did
  not extend to this file.

## Why :52 (test941ProtocolCompletionDoesNotEndTheGaugeSession) was also seen failing
Same mixture mechanism: `tindeqEntryCount(model) == entriesBefore` reads a published
sessions array hydrated from a container holding earlier runs' "tindeq" sessions for
the same fixed account.

## Why StructuralHapticsWiringTests:111 is NOT timing-sensitive
It scans only `Sources/**` under the test bundle's #filePath for a literal that is
present exactly once at base, head, reviewer head (git grep across 0516b657 / 3bbec7e
/ c273627f0 = 1 occurrence, StructuralHaptics.swift:86). The only environmental
inputs are the filesystem walk and the string strips. Its base failure (reviewer's
report) is not explained by a bounded wait; it failed on a FRESH sim where this lane
passes, so container/environment differences remain the suspect — recording it as
UNSTABLE-ATTRIBUTED-ENVIRONMENT with the missing measurement named in the report.

## Treatment applied (fence-compliant)
- waitUntil() helper (60 s ContinuousClock deadline, 5 ms poll, expiry diagnostic
  printing elapsed + observed state incl. the durable queue file) — the #970 shape.
- makeSignedInModel: fixed 200-yield budget -> deadline-bound wait + authState
  diagnostic. Assertion unchanged.
- back-to-back test: deadline-bound waits for the published group rows before BOTH
  :88 and :98 assert sites. Assertion values unchanged (2, 1, note equality…).
- red-probe diff (committed as evidence only): saveRep save refused ->
  hardened wait must time out and print the diagnostic.
