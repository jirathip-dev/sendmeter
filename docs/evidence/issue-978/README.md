# issue-978 evidence — impl-978 lane

Base: `c273627f0fdff5b48088066a880483bada365272` (origin/staging at lane start).
Head: see `gate-head-sha.txt` / `.report-1.md`.
Simulator: `iphone17pro-sendmeter`, UDID `0E127B96-BF94-48E0-A61B-0C018D9D79C7`, iOS 26.5.

Every file below is a raw `xcodebuild test` log (gzipped) unless noted. The full
command shape for every run is byte-identical to `.github/workflows/native-swift.yml`
("Build and test native app target") with ONE documented deviation: an explicit
`-derivedDataPath /Users/jirathip/.herdr/dd/impl-978` because the host's Xcode
default DerivedData volume (`/Volumes/NVMe2TB`, an external drive) was NOT MOUNTED
for the whole lane — Xcode failed with exit 74 (permission errors writing to the
dangling path) before this override. This is a lane-level environment bypass,
recorded per-run in `run-ledger.txt`; the default external contract remains.

## Base (unmodified tree) — reproduces the hosted failure

- `base-1-guided.log.gz` — base tree, GuidedProtocolCompletionTests, exit **65**:
  `:88` and `:98` `XCTAssertEqual failed: ("1") is not equal to ("2")` — the same
  two assertions as hosted job `106031119035` on staging-identical content.
  (First attempt in this log is the exit-74 DerivedData failure described above.)
- `base-2b-guided-clean.log.gz` — PRISTINE base tree in a separate worktree
  (`/tmp/impl978-base`, own generated project + DerivedData), app container
  uninstalled first: exit **0**, 3/3 pass in 0.134 s. The base failure needs the
  shared-container repetition condition; it does not reproduce on a clean
  container even unhardened. This anchors "same sim, same command, one variable".

## Head (hardened waits) — GuidedProtocolCompletionTests

Quiet (clean container per run, sim `uninstall` before each):
- `head-2-guided.log.gz`, `head-q-1..5.log.gz` — 6 runs, all exit **0**
  (0 failures; per-test ~0.05 s; suite 0.104–0.126 s).

Contended:
- `head-c-1..5.log.gz` — 5 runs with 8 CPU burners + a CONCURRENT xcodebuild from
  another lane (review-935-r1, visible in the ledger lines), all exit **0**
  (suite 0.104–0.449 s). The lane holds one-xcodebuild-at-a-time for ITS runs;
  the concurrent lane was not ours to throttle and is exactly the contention
  the issue describes.

## StructuralHapticsWiringTests (checked for the same shape)

- `head-haptics.log.gz` + `haptics-q-1..5.log.gz` (quiet) and
  `haptics-c-1..5.log.gz` (contended) — 11 runs, all exit **0**, 6/6 tests,
  0.167–0.551 s. No bounded/polling wait exists in this file (it is a source-text
  scanner, no sleeps); its observed base failures correlate with
  container/environment state, not timing — see .report-1.md attribution.

## RED proof (hardened wait still fails when the behaviour is broken)

- `red-probe-splice.diff` — the committed-splice evidence: applied ONLY in the
  scratch worktree `/tmp/impl978-probe` (detached HEAD c273627f0), never committed
  to the lane branch, never applied to product source. The break: protocol 2's
  rep save is skipped, so the grouped behaviour the test waits for genuinely does
  not happen while everything else runs the real boundary.
- `red-probe-10.log.gz` — with the splice active, the hardened wait TIMED OUT:
  - `timed out after 60.004090083 seconds waiting for the published recordings to
    hold 2 row(s) for the live group; observed liveGroup=40FBC89C, expected=40FBC89C,
    groupRows=1, recordings=[B1A71712@40FBC89C/FDP], sessions=0, tindeqEntries=0,
    queuedWrites=1, pending-writes.json 1992 bytes, 1 item(s)`
  - second wait (post-end): `timed out after 60.00103375 seconds … liveGroup=nil …
    tindeqEntries=1, queuedWrites=2, pending-writes.json 2798 bytes, 2 item(s)`
  - then `:129`/`:143` failed `1 != 2`; overall exit **65**. The diagnostic
    distinguishes slowness from a real regression exactly as required.
  - `red-probe.log.gz` and earlier probe attempts (5-9) are the diagnostic
    lineage: shared-container contamination of the probe itself, splice
    keying fixes, and a runner `Fatal error` iteration — kept for honesty.
- `container-state-after-base-run.txt` — raw queue/cache dump method; the
  verbatim post-base-1 dump (5 items incl. the never-retried protocol-3 rep) is
  in `root-cause-notes.md` and the run-ledger notes.

## Root cause work

- `root-cause-notes.md` — mechanism analysis with source lines: two independent
  interleavings (hydration reset racing the detached-upload ack; fixed test
  account + shared on-disk container across repetitions) that produce the
  observed `1 != 2` and moving assertion lines, and why `:52` fails via the
  same shared-state path.
- `run-ledger.txt` — every run: label, selector, cleanContainer flag, UTC times,
  elapsed, host load, concurrent xcodebuild/xctest PIDs, DerivedData override.
