# #1020 — build 57's every-launch unreadable-data banner

**Verdict: NAMED from the owner's real data, and it is not a bad row.** Every row of the owner's
account decodes. The failure is the client's own timestamp precision. Postgres `timestamptz` (so
every PostgREST `updated_at`) carries **microseconds**. `LocalDateSupport.iso8601Date` used
Foundation's `ISO8601DateFormatter` with `.withFractionalSeconds`, which keeps only **milliseconds**,
and `DeltaCursor.parse`'s `DateFormatter` (`SSSSSS`) truncated the same way.

The delta reader therefore persisted a cursor up to 999 µs *behind* the row it last read. On the
**next** launch, `updated_at.gt.<cursor>` re-served that row, and the reader failed closed
(`DeltaReadError.cursorDidNotAdvance`, or `outOfOrderPage` for a same-millisecond group whose
microsecond order disagrees with its id order). That classifies as `.dataUnreadable`, which is the
banner on every launch after the first sync.

The orchestrator's step-0 probe only ran `cursor == nil` (launch 1), which passes, so it could not
see this.

- Slice: all nine refresh slices. `presets` and `tagMetadata` fail as `outOfOrderPage`; the other
  seven fail as `cursorDidNotAdvance`.
- `codingPath`: none. There is no `DecodingError`; the "unreadable" error is the delta reader's
  fail-closed check.
- Value shape: `updated_at` text with a fraction of 4–6 digits, e.g. `…:10.123456+00:00`. It is 100%
  of the owner's rows: 888 of 888.

No row value from the owner's account is committed here. The files below are counts, verdicts and
methodology only; the owner id in the SQL is replaced by `:owner_user_id`.

## Artifacts

| File | What it is |
| --- | --- |
| `resumed-launch-harness.swift.txt` | The resumed-launch extension appended to the orchestrator's probe (`~/.herdr/orch-scripts/sm-1020-probe/dp/main.swift` lines 1–797: the real `DeltaPageReader`, the real Row types and the real date strategy). It runs launch 1 → 2 → 3 per slice. The "server" filters and orders on the TRUE microseconds parsed digit-by-digit from the raw JSON text, never on the client's decoded `Date`. |
| `resume-before-fix.txt` | Real-data run with the build-57 parser, RAW_EXIT=0 (the harness prints verdicts and exits 0). **All 9 slices FAIL on the first resumed launch.** `decodedDate!=serverMicros` holds for every row. |
| `resume-after-fix.txt` | Same harness with the fixed parser and cursor parse spliced in (bodies byte-identical to HEAD; verified with `diff`): every slice survives three launches. |
| `resume-heal-old-cursor.txt` | `--heal`: launch 2 starts from the millisecond-truncated cursor build 57 already persisted on the device. Every slice re-reads its last row once (an idempotent re-apply), stores the exact stamp, and launch 3 is empty. The device self-heals on its first launch of the fixed build, with no cache reset and no reinstall. |
| `server-reserve-count.sql.txt` / `.json.txt` | Server-side confirmation (Management-API SQL, SELECT only, `sm-sql.sh prod`). For each slice it counts the rows Postgres serves for the client's millisecond cursor (`served_for_ms_cursor` ≥ 1, i.e. presets 4 and tags 6) versus the exact cursor (`served_for_exact_cursor` = 0). It also counts the rows whose JSON text has a sub-millisecond fraction (`json_agg_submillis` = every row). |
| `red-before-fix.log.gz` | Core RED: `swift test --filter DeltaCursorPrecisionTests` on the build-57 `DateSupport.swift` + `DeltaCursor.swift` (tests at HEAD). RAW_EXIT=1: 9 failures, including `cursorDidNotAdvance` and `outOfOrderPage`. |
| `app-red-before-fix.log.gz` | App-target RED: `PersistedFailureLogAppTests/testSecondLaunchAtMicrosecondServerStampsRefreshesWithoutAFailure` on the same base files. RAW_EXIT=65. The captured line is `launch failure step=refresh-slice:sessions … class=dataUnreadable … delta=cursorDidNotAdvance`. |
| `app-mutation-one-line.log.gz` + `probe-ac3-one-line-mutation.diff` | AC3 mutation: `recordPartialRefresh` put back to its one-representative-line form. `testEveryFailedSliceGetsItsOwnLineNamingTheCodingPath` goes RED (RAW_EXIT=65). |
| `redaction-mutation.log.gz` | AC3 mutation: the dictionary-key redaction guard removed. `PersistedFailureLogTests` goes RED (RAW_EXIT=1, `path=by_tag.crimp` leaked). |
| `app-tests.log.gz` | App-target GREEN at `e0a0acd`: `PersistedFailureLogAppTests` + `PagedDeltaTransportTests` + `DashboardLoadFailureAppTests`, 19 tests, RAW_EXIT=0. |
| `just-core.log.gz` | `TZ=UTC just core` (the full SwiftPM suite) at `e0a0acd`: 1535 tests, RAW_EXIT=0. |
| `focused-green.log.gz` | The focused Core filter run during development. RAW_EXIT=0, 80 tests. |
| `xcodebuild-build.log.gz` | App build at `32a7bc8`, lane-local `-derivedDataPath`, RAW_EXIT=0. (`e0a0acd` changes only Core, which the app-test run above rebuilt.) |
| `just-slop.log.gz`, `just-docs-check.log.gz`, `just-list.log.gz`, `git-diff-check.txt` | Static gates at `e0a0acd`, all RAW_EXIT=0. The diff check output is empty. |
