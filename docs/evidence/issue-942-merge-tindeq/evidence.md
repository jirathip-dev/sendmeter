# #942 — History: merge same-day Tindeq sessions

Lane: `impl-942` · worktree `/Users/jirathip/.herdr/worktrees/sendmeter/impl-942`
Base: `0d79a0897f1735410e64dd6bcd5da31de0509c8e` (`origin/staging`)

## What ships

| Layer | Artifact |
|---|---|
| SQL (atomic server op) | `supabase/migrations/20260918090000_merge_tindeq_sessions_rpc.sql` — `public.merge_tindeq_sessions(uuid[], uuid, numeric, boolean)`, `security invoker`, one transaction: lock the selected rows, validate (tindeq / one local day / owned / live), re-point every recording of every selected group (trashed ones included) to the survivor's group, rebuild duration + note from the moved recordings, write the plan's RPE, soft-delete the other sessions. |
| SQL regression | `supabase/tests/merge_tindeq_sessions.sql` — 37 pgTAP assertions: cross-account RED (real `set local role authenticated` + `request.jwt.claim.sub`), cross-day / non-Tindeq / survivor / degenerate RED, mid-function atomicity rollback, GREEN merge, idempotent retry, RLS visibility. Added to the `Supabase SQL` workflow as its own step. |
| Core (pure plan) | `Sources/Core/TindeqSessionMerge.swift` — eligibility, candidate list, and the merge plan (survivor = earliest-recorded start, duration = `GaugeSessionDuration.spanMinutes`, note = `GaugeSessionNote.build`, RPE = `GaugeSessionRPE.predict` unless a confirmed one is kept). |
| Data | `Repositories.swift` — `mergeTindeqSessions(...)` → `POST /rest/v1/rpc/merge_tindeq_sessions`, plus the RPC body/result types. |
| App | `AppModel.swift` — `mergeTindeqSessions(_:)` (optimistic fold + durable queue write), `mergePreview(_:)` for the sheet, `PendingWrite.sessionMerge` upload/restore paths, `pendingMergedAwaySessionIDs` so a refresh cannot resurrect merged entries. |
| UI | `Features/History/HistoryView.swift` — row context menu "Merge with…" (gated to uploaded, grouped Tindeq rows) → confirm sheet that multi-selects same-day siblings and previews the exact plan before writing. |
| Notes | `RELEASE_NOTES.md` Unreleased → Added. |

## How it was verified

### Swift lanes (host)

| Gate | Command (and raw exit) | Log |
|---|---|---|
| Fast lane | `just fast` → **EXIT 0** (`slop` structure check + `core` **1220 tests, 0 failures** + `watch-core` + `health-core`) | `/tmp/impl942-fast-final.log` |
| Anti-slop (real linter) | `bash scripts/anti-slop-swift.sh` → **EXIT 0**, `anti-slop: scanned 152 Swift files`, 0 violations | `/tmp/impl942-antislop-final.log` |
| App build | `just build-ios` → **EXIT 74** (host DerivedData is pinned to the unattached `/Volumes/NVMe2TB`; SPM `SourcePackages` permission) | `/tmp/impl942-build-ios-default.log` |
| App build (worktree cache) | `just gen` then `xcodebuild … -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -derivedDataPath /Users/jirathip/impl942-derived build` → **BUILD SUCCEEDED, EXIT 0** | `/tmp/impl942-xcodebuild-build3.log` |
| App-target tests | `xcodebuild test … -destination "id=0E127B96-BF94-48E0-A61B-0C018D9D79C7" -only-testing:SendmeterNativeTests CODE_SIGNING_ALLOWED=NO -derivedDataPath /Users/jirathip/impl942-derived` → **EXIT 0, 37 tests, 0 failures** | `/tmp/impl942-xcodebuild-test3.log` |
| Core mutation probe | merge plan mutated to keep the survivor's own duration/note → `swift test --filter TindeqSessionMergeTests` **EXIT 1, 7 assertions RED**; restored → **EXIT 0** (file byte-identical after restore) | `/tmp/impl942-probe-mutated.log`, `/tmp/impl942-probe-restored.log` |

The `SendmeterNativeTests` bundle carries the end-to-end merge evidence
(`TindeqSessionMergeAppTests.swift`): a real `AppModel` against a stubbed
PostgREST transport — three same-day entries fold into one, the recordings land
under the surviving group, the RPC body carries the plan, an offline merge stays
queued and uploads exactly once on reconnect, and ineligible selections never
build a request. `MergeSessionsWiringTests.swift` pins the UI half (the merge
action's gate, the sheet's planner-backed preview, the confirm path).

### SQL lane

The repo's SQL lane is `supabase test db --local` (Docker) or the hosted
`Supabase SQL` job. **Docker/colima is not available on this host and was not
started** (lane constraint), and a push to a lane branch does not trigger the
hosted workflow (it runs on pushes to `main`/`staging` and on PRs targeting
them; the PR is opened by the orchestrator). So the committed pgTAP file was
executed against a **scratch PostgreSQL 17.11 cluster** (host `postgresql@17`
binaries, `initdb` under `/tmp`, no system change, no Docker) with:

* a scaffold standing in for the parts of the supabase/postgres image the
  migrations depend on (roles, `auth` schema + `auth.uid()`, `extensions` +
  pgcrypto, the `supabase_realtime` publication),
* every migration in `supabase/migrations/` applied in filename order
  (`scratch-postgres-migration-chain.log`, all applied, including the new one),
* a local pgTAP-compatible shim (`plan`/`is`/`throws_ok`/`finish`) so the
  committed test file runs **verbatim** — not a rewritten scenario.

Result: `psql -f supabase/tests/merge_tindeq_sessions.sql` → **EXIT 0, 37/37
assertions passed** (`sql-green-scratch-postgres.log.gz`). Removing the ownership
count guard (the RLS-driven "session not found" rejection) makes it **fail 3 of
37 with EXIT 3**, the cross-account cases among them
(`sql-red-mutation-no-ownership-guard.log.gz`) — the test bites.
The three `.log.gz` files beside this document are the byte-exact psql output
(gzipped because the repo ignores `*.log` and psql's aligned table headings
carry trailing whitespace that trips `git diff --check`).

**Honest limits of that lane:** it is NOT the supabase/postgres image and NOT
real pgTAP, so the authoritative SQL result is the hosted `Supabase SQL` job at
PR time. The shim's `is()`/`throws_ok()` semantics match pgTAP's for the
constructs this file uses (3-arg `is`, `throws_ok` with a NULL message).

## Acceptance criteria

| AC | Status | Evidence |
|---|---|---|
| 1. Three same-day Tindeq entries → one entry (count = sum, duration = span, note lists all) | covered | `TindeqSessionMergeTests` (Core) + `TindeqSessionMergeAppTests.testMergeFoldsThreeSameDayEntriesIntoOneAndKeepsEveryRecording` + SQL GREEN block |
| 2. Recordings stay visible in `SessionDetailView` | covered | app test (3 recordings under the surviving `groupID`), `MergeSessionsWiringTests.testSessionDetailStillGroupsRecordingsByTheSurvivingGroup`, SQL "no recording left behind" |
| 3. Cross-user / cross-day / non-Tindeq rejected in UI **and** by the RPC | covered | SQL RED + RLS blocks (foreign, cross-day, non-Tindeq, survivor, degenerate, replay) and `TindeqSessionMergeAppTests.testIneligibleSelectionsAreRefusedWithoutContactingTheServer` + the planner/wiring pins (UI gate uses the same planner) |
| 4. Offline: queued and applied on reconnect; no duplicate sessions | covered | `TindeqSessionMergeAppTests.testOfflineMergeIsQueuedAndAppliedOnReconnectWithoutDuplicates` (queue 1 → refresh keeps the fold → one upload → 0, one entry) + the SQL idempotent-retry block |
| 5. Simulator screenshots of the selection state and merged result | **OPEN** | See the report's blocker: the merge UI needs a signed-in session with real history rows, and the only launch-argument fixture seam lives in `Sources/App/SendmeterNativeApp.swift`, which this lane is fenced out of. |
| 6. `RELEASE_NOTES.md` Unreleased entry | covered | `RELEASE_NOTES.md` |

## Not verified in this lane

* The hosted `Supabase SQL` job (does not trigger from a lane-branch push; needs
  the PR).
* `just ci` / `just build-watch` / `just check-watch-project` were not run (the
  brief's gate list is `just --list`, `just fast`, `just gen` + the two
  xcodebuild invocations; the host's pinned DerivedData breaks the default
  DerivedData path anyway).
* No device/TestFlight verification of the merge UI.
