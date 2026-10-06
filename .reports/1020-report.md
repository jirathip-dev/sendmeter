# 1020-report — build 57's every-launch unreadable-data banner (issue #1020, lane `impl-1020`)

**STATUS: DONE.** AC1–AC5 are met. AC6 is the owner's device gate and is left unchecked on purpose.
**Branch:** `impl-1020` (pushed). The exact pushed tip is the last commit of the lane
(`git log --oneline -1 origin/impl-1020`). That tip contains this report, and its delivery head is quoted in the final lane
message. **No PR was opened or merged**, per the brief.

Commits on `c55b06c` (origin/staging):

- `32a7bc8`: the fix, tests and step-0 evidence. The orchestrator committed it verbatim from this lane's
  working tree after a provider outage killed the lane. Its message calls it WIP; this lane
  re-verified it below.
- `e0a0acd`: hardens the AC3 redaction. An identifier-shaped dictionary key, for example a tag named
  `crimp`, is user data and now logs as `?`.
- The tip commit adds this report, the evidence README and the gzipped gate logs.

## 1. Step 0 verdict: the failing payload is named, and it is not a bad row

**Every row of the owner's account decodes cleanly. The banner is the delta reader failing closed on
the second and later launches, because the client truncated every server `updated_at` from
microseconds to milliseconds.**

### Mechanism

1. Postgres `timestamptz` carries microseconds. In the owner's data, 888 of 888 rows across the nine
   slices have a sub-millisecond fraction (`json_agg_submillis` in `server-reserve-count.json.txt`).
   That count is the fraction digits as Postgres's JSON serialisation emits them, which is the same
   `timestamptz` → JSON text path PostgREST uses.
2. `LocalDateSupport.iso8601Date` (`Core/DateSupport.swift`, which `PostgRESTClient`'s
   `dateDecodingStrategy` calls) used `ISO8601DateFormatter` + `.withFractionalSeconds`, which keeps
   **milliseconds** only. The scratch probe showed `…10.123456+00:00` → 123000 µs.
   `DeltaCursor.parse`'s fixed-width `DateFormatter` (`SSSSSS`) truncated the same way.
3. `DeltaPageReader.advance` builds the persisted cursor from that truncated `Date`. That puts the
   cursor up to 999 µs behind the row it stands on.
4. On the next launch, the server evaluates `or=(updated_at.gt.<ms-stamp>,…)` on the true
   microseconds and re-serves that row. The reader sees `next == cursor`, throws
   `DeltaReadError.cursorDidNotAdvance`, and that classifies as `.dataUnreadable`.
5. Two slices take a different path. `presets` and `tagMetadata` each have rows written within one
   millisecond, and their microsecond order disagrees with their id order. Collapsed to one
   millisecond, the client's `(stamp, id)` key disagrees with the server's order, so the reader throws
   `outOfOrderPage` instead.
6. The orchestrator's step-0 probe ran `cursor == nil` (launch 1) only. Launch 1 passes, which is
   why every slice looked clean.

### AC1 statement

- **Slice:** all nine. `presets` and `tagMetadata` fail with `outOfOrderPage`; the other seven fail
  with `cursorDidNotAdvance`. `healthMetrics` and `workoutsAndAttempts` fail at launch 3, because
  their first sync is the legacy window.
- **`codingPath`:** none. No `DecodingError` is raised; the error is the reader's fail-closed check.
- **Value shape:** the `updated_at` text carries 4–6 fraction digits (e.g. `…T23:22:10.123456+00:00`).
- **Local or server:** neither a local cache payload nor a malformed server row. It is a
  client-side precision loss applied to valid server rows.

### Commands and raw output

These ran on the owner's real rows. Fixtures stay local; no values are committed.

| Surface | Command | Raw exit | Result |
| --- | --- | --- | --- |
| 9 slices, launches 1→3, build-57 parser | `./resumeprobe ~/.herdr/orch-scripts/sendmeter-1020-deltas` (the orchestrator's `dp/main.swift` lines 1–797 plus the appended `resumed-launch-harness.swift.txt`) | 0 (the harness prints verdicts and exits 0) | **9/9 FAIL on the first resumed launch**: `docs/evidence/issue-1020/resume-before-fix.txt` |
| Same, fixed parser (bodies byte-identical to HEAD, verified with `diff` → `PARSER_BODY_IDENTICAL`, `CURSOR_PARSE_IDENTICAL`) | same | 0 | 9/9 survive three launches: `resume-after-fix.txt` |
| Same, starting from build 57's already-persisted millisecond cursor | `./resumeprobe … --heal` | 0 | 9/9 heal. Launch 2 re-applies the last row once, launch 3 is empty: `resume-heal-old-cursor.txt` |
| Server-side confirmation | `~/.herdr/orch-scripts/sm-sql.sh prod "$(cat reserve.sql)"` (SELECT only; the token was never printed) | 0 | Rows served for the ms cursor: 1 per slice, 4 for presets, 6 for tags. Rows served for the exact cursor: 0 for all. `server-reserve-count.{sql,json}.txt`, owner id replaced by `:owner_user_id` |

The rest of step 0 was a bounded pass over the other surfaces the brief named. These are static
eliminations, not a real-data run, and are stated as such:

- **`fetchSettingsSlice` today-scoped work.** It is a second `fetchSettingsDelta(since: nil)` plus
  `fetchSettings` (`SettingsRow`). Both use the same decoder and the same `SettingsRow` the
  orchestrator decoded cleanly. It runs only on a first sync with no settings row, which does not
  apply here (1 row exists).
- **Purge generation.** `fetchPurgeSyncGeneration` returns zero rows for the owner, which collapses
  to generation 0 by design (orchestrator step 0). Its failure would be a refresh-wide `catch`, not
  the per-slice path.
- **Tag-curve / sample path.** `warmTagCurveIfMissing` runs in a detached `Task<Void, Never>` after
  publication (`AppModel.swift` around :5066). It cannot fail the refresh or raise the banner.
- **`.rpc` returns.** None is awaited by `refreshAll`. All eight `rpc/` paths in `Repositories.swift`
  are user-action writes: `create_phone_workout`, `delete_account`,
  `link_tindeq_recordings_to_session`, `merge_tindeq_sessions`, `purge_recording`, `purge_session`,
  `rename_tindeq_tag`, `upsert_health_metrics_with_precedence`.
- **Live-workout mirror.** It decodes with the same parser (`LiveWorkoutMirror.isoDate`). The
  orchestrator found the owner's one row decodes. It is not a refresh slice.
- **App-written payloads.** Cache rows, the durable queue, `RoutineGate`'s persisted run,
  `AuthDiagnostics` and `LostRecordingNotice` all use `JSONEncoder`/`JSONDecoder` with matching
  `.iso8601` (or default) strategies on both sides. A local decode failure surfaces as
  `LocalCacheError.invalidPayload` / quarantine (#1004), not as the per-slice `DeltaReadError` the
  device path produces. Their suites (`OfflineQueueTests`, `RoutineGateTests`,
  `AuthDiagnosticsTests`, `LocalCacheRepairTests`, `LostRecordingNoticeTests`) pass inside
  `just core`.
- **Cache `updated_at` text.** `LocalCacheStore.timestamp` (which `syncCursorString` calls) already
  writes the seconds via `DateFormatter` and appends exact integer microseconds, so the persisted text
  was exact for whatever `Date` it got. Only the parse feeding that `Date` lost precision, and the fix
  removes that loss.

**Gap, stated honestly.** There are still no live PostgREST bytes (no owner session token exists).
The real-data evidence comes from Postgres's own JSON serialisation of `timestamptz`, through
`row_to_json` / `json_agg`, plus a server-side SQL count of the re-serve. PostgREST serialises
`timestamptz` through the same Postgres JSON output, so the precision claim holds. The device log
was not pulled (`log collect` needs root, per the orchestrator's comment).

## 2. Acceptance criteria

All logs are under `docs/evidence/issue-1020/` (gzipped; `*.log` is gitignored). The raw `.log`
files also sit in `.reports/`, which is ignored.

### AC1 — Met

The failing payload is named from real data (§1).

### AC2 — Met, via the brief's "fix the model/schema mismatch" branch

The rows were never undecodable. The mismatch was the client's precision against the server's
microseconds.

The fix is in `Core/DateSupport.swift`. `iso8601Date` now adds the fraction as exact integer
microseconds (up to 6 digits; extra digits are truncated, as Postgres stores at most 6) on top of
Foundation's whole-second parse. Strings without a fraction take the unchanged Foundation path.

`Core/DeltaCursor.swift` parses persisted stamps through that same function, and the
millisecond-only `fixedWidthFormatter` is gone.

**Heal:** an existing millisecond cursor re-reads its last row once, as an idempotent server
re-apply, then stores the exact stamp. There is no cache reset, no reinstall, and no change to any
pending-write path.

**Other slices stay published:** the existing #923 per-group publication is unchanged.
`testEveryFailedSliceGetsItsOwnLineNamingTheCodingPath` asserts that two unreadable slices hold back
only `[.presets, .tagMetadata]` while sessions and recordings publish.

**Local unsynced writes:** untouched. No file in the queue or cache-write path changed. The full
Core suite passes, including `OfflineQueueTests` and `LocalCacheRepairTests`.

**Not done:** per-row skip/set-aside of an undecodable server row. AC2 offers it as an alternative
to fixing the mismatch, and no undecodable row exists.

### AC3 — Met

`PersistedFailureLine` gains `detail`, which appears in the message as
`… surfaced=<b> decode=<kind> path=<keys>` or `… delta=<case>`.

- It is built from the error's structure only:
  - array indices become `*`
  - non-identifier keys, and any Foundation dictionary key (`e0a0acd`), become `?`
  - `debugDescription` is dropped, because it can quote the value
- `recordPartialRefresh` now emits one line **per failed slice**. Only the representative line
  carries `surfaced`. Build 57's capture would have named only `refresh-slice:sessions`.
- The production sink (`PersistedFailureLog.swift:137`) logs `line.message` with
  `logger.notice(… privacy: .public)`, so `detail` reaches the persisted device log.

### AC4 — Met

The copy is now "Sendmeter couldn't read some of its data. Try again."
(`Core/FriendlyError.swift:135`). It no longer promises "set aside and rebuilt from your account".
It does not advise reinstalling, and it does not suppress the error. The banner layout is untouched.

### AC5 — Met

RED witnesses that fail before the fix and pass after it.

### AC6 — Not met; left unchecked

This is the owner's device gate: build N+1 cold launch, then a second launch with no banner. This
lane cannot run it.

### Gate results

| Check | Command | Raw exit | Log |
| --- | --- | --- | --- |
| AC5 Core RED | base `DateSupport.swift`+`DeltaCursor.swift` (`git checkout c55b06c -- …`, tests at HEAD), `TZ=UTC swift test --filter DeltaCursorPrecisionTests` | **1**: 9 failures, incl. `cursorDidNotAdvance`, `outOfOrderPage`, `123000 != 123456` | `red-before-fix.log.gz` |
| AC5 app RED | same base files, `xcodebuild test … -only-testing:SendmeterNativeTests/PersistedFailureLogAppTests/testSecondLaunchAtMicrosecondServerStampsRefreshesWithoutAFailure` | **65**: captured `launch failure step=refresh-slice:sessions domain=SendmeterCore.DeltaReadError code=2 class=dataUnreadable surfaced=false delta=cursorDidNotAdvance` | `app-red-before-fix.log.gz` |
| AC3 mutation (one representative line) | `probe-ac3-one-line-mutation.diff` applied, `-only-testing:…/testEveryFailedSliceGetsItsOwnLineNamingTheCodingPath` | **65** | `app-mutation-one-line.log.gz` |
| AC3 redaction mutation (dictionary-key guard removed) | `TZ=UTC swift test --filter PersistedFailureLogTests` | **1**: `path=by_tag.crimp` leaked | `redaction-mutation.log.gz` |
| Restore after every leg | `git checkout HEAD -- <files>; git diff --quiet HEAD -- Sources Tests` | 0 each time | — |
| Full Core suite | `TZ=UTC just core` at `e0a0acd` | **0**: 1535 tests, 0 failures | `just-core.log.gz` |
| App-target suites | `xcodebuild test … -derivedDataPath ./.dd -only-testing:{PersistedFailureLogAppTests,PagedDeltaTransportTests,DashboardLoadFailureAppTests}` at `e0a0acd` | **0**: 19 tests, 0 failures, `** TEST SUCCEEDED **` | `app-tests.log.gz` |
| App build | `xcodebuild … -derivedDataPath ./.dd … build` at `32a7bc8` | **0** (`** BUILD SUCCEEDED **`) | `xcodebuild-build.log.gz` |
| Static, at `e0a0acd` | `just slop`, `just docs-check`, `git diff --check c55b06c..HEAD` | **0 / 0 / 0** | `just-slop.log.gz`, `just-docs-check.log.gz`, `git-diff-check.txt` |

The `just build-ios` recipe is host-blocked per the brief. The equivalent `xcodebuild` ran with a
lane-local `-derivedDataPath ./.dd` on the one available simulator, `iphone17pro-sendmeter`. No
"iPhone 16 Pro" exists on this host.

## 3. Diff scope and fence

Files touched, `c55b06c..HEAD`:

- `native/SendmeterNative/Sources/Core/{DateSupport,DeltaCursor,FriendlyError,PersistedFailureLog}.swift`
- `native/SendmeterNative/Sources/App/AppModel.swift`, `recordPartialRefresh` only (the per-slice
  loop)
- `native/SendmeterNative/Tests/SendmeterCoreTests/{DeltaCursorPrecisionTests (new),FriendlyErrorTests,PersistedFailureLogTests}.swift`
- `native/SendmeterNative/Tests/SendmeterNativeTests/PersistedFailureLogAppTests.swift`
- `docs/evidence/issue-1020/**`
- `.reports/1020-report.md`

The fence held. The out-of-fence grep over `git diff --name-only c55b06c..HEAD` returned nothing
(exit 1). `SendmeterNativeApp.swift`, `DesignSystem.swift`, schema, migrations, dependencies and
`Package.resolved` are untouched; `swift build` rewrites `Package.resolved` locally, and that change
was reverted before every commit.

The report is `.reports/1020-report.md`, per the brief's output contract. The raw `.reports/*.log`
files stay local because `*.log` is gitignored; their gzipped copies are in
`docs/evidence/issue-1020/`. No owner row values, ids or tokens are in any committed file; a grep of the
logs for `sbp_`, JWT, `Bearer`, the owner id and `service_role` returned 0 hits each.

## 4. Deferred

- **AC6** (device): owner. After this ships, the next capture, if anything still fails, names the
  slice and the decode path or delta case by itself.
- **Per-row skip of an undecodable server row:** not built. No such row exists, and AC2's
  mismatch-fix branch applies. Building a skip path for a failure that does not occur would be
  speculative.
- **Live PostgREST bytes:** no owner session, so not captured (see the gap in §1).
