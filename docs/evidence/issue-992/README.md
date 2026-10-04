# Evidence — #992 (native/observability)

Lane `impl-992`, worktree `~/.herdr/worktrees/sendmeter/impl-992`, branch `impl-992`.

## What was proven here

Failure logging on the launch path and the sync/replay path now raises
`.notice` lines (persisted by default in the unified log — `log show` without
`--info`/`--debug` sees them), carrying operation, error domain + code, the
taxonomy class, and whether the failure was surfaced to the user.

Three legs, all real runs:

1. **Behaviour / fields (app-target, simulator):** `PersistedFailureLogAppTests`
   drives a REAL `AppModel` against a stubbed PostgREST transport, through a
   transport that fails exactly like a device does (`URLError(.notConnectedToInternet)`),
   and asserts the lines at the injectable sink (`AppModel.persistedFailureSink`,
   production default = the os.Logger emission). RED-proved by mutating the
   level and by dropping the surfaced field (see `red/`).
2. **Persistence (simulator unified log):** the app is built, installed and
   launched in a booted simulator; real failures occur (watch transmit, and a
   real rejected sign-in driven through the app's own form by
   `SignInFailurePersistedLineUITests`); then the unified log is read with
   **persisted levels only**:

   ```bash
   xcrun simctl spawn <UDID> log show --last 12m --predicate 'process == "Sendmeter"' --style compact
   ```

   (`booted` in the issue's command is pinned to this lane's simulator UDID
   because a second, shared simulator is booted on this host.)

   Captured lines (raw, `Df` = the persisted default/notice tier):

   ```
   [com.jirathip.sendlog.native:sync-replay-failure] sync/replay failure op=watch-transmit domain=WCErrorDomain code=7005 class=unknown surfaced=false
   [com.jirathip.sendlog.native:launch-failure] launch failure step=banner domain=Auth.AuthError code=1 class=authRejected surfaced=true
   ```

3. **Core line shape (SwiftPM, host):** `PersistedFailureLogTests` pins the
   emitted shape for both channels.

**This is the simulator, not a device.** The level-filtering rule the issue
turns on — `.info`/`.debug` messages are not shown without `--info`/`--debug`,
`.notice`/`.default` are — is the same rule in both stores, which is why this
is a valid persistence check; it is NOT a device result and is not claimed as
one. The device leg (`log collect` needs USB; `devicectl device sysdiagnose`
fails on this host) is OWNER-GATED and PENDING — command in `device-pending.md`.

## Files

Bare `*.log` files are gitignored in this repo, so every raw run log is
committed gzipped (`.log.gz`); `zcat`/`gunzip` to read.

| File | What it is |
| --- | --- |
| `gate-slop.log.gz` | `just slop` raw log (exit 0) |
| `gate-core.log.gz` | `just core` raw log (exit 0, 1498 tests) |
| `gate-check-static.log.gz` | `just check-static` raw log (exit 1 — PRE-EXISTING at base, documented) |
| `gate-anti-slop-lint.log.gz` | advisory `scripts/anti-slop-swift.sh` output (the base's 2 findings) |
| `gate-app-build.log.gz` | app-target xcodebuild build (exit 0) |
| `gate-app-tests-focused.log.gz` | focused `PersistedFailureLogAppTests`: attempt-1 FAIL (wrong labels) + attempt-2 GREEN |
| `gate-app-tests-full.log.gz` | full `-only-testing:SendmeterNativeTests` run (exit 0, 172 tests) |
| `gate-ui-signin.log.gz` | `SignInFailurePersistedLineUITests` run (exit 0; the drive of the `step=banner` line) |
| `gen.log.gz` | `just gen` log |
| `sim-happy-path.log.gz` | persisted-levels-only log after a successful cold launch (`op=watch-transmit` lines only) |
| `sim-failure-fields.log.gz` | persisted-levels-only log after the failure-driven app-target run |
| `sim-failure-launch-funnel.log.gz` | persisted-levels-only log of the corrupted-cache negative probe (no line — signed-out launches never open the cache) |
| `sim-banner-signin.log.gz` | persisted-levels-only log containing the rejected sign-in's `step=banner … surfaced=true` line |
| `sim-*.stderr.log.gz` | stderr of the `log show` calls (empty) |
| `cache-corrupt-pre.sha`, `cache-corrupt-post.sha` | sha256 of `local-cache.sqlite` before/after the negative-probe corruption |
| `install-identity.txt` | sha256 of the installed `Sendmeter.debug.dylib` == the built product (the measured build identity) |
| `red/probe-a.diff`, `red/probe-b.diff` | the two mutation diffs (level; surfaced) |
| `red/red-core-level.log.gz` | RED-A raw run (exit 1, 2 failures) |
| `red/red-surfaced-focused.log.gz` | RED-B raw run (exit 65) |
| `site-table.md` | site → level → persisted? → changed? enumeration |
| `device-pending.md` | the owner's exact device commands (pending bar) |
| `SHA256SUMS` | sha256 of every committed file in this directory |

Redaction statement: the lines carry only fixed labels written in code (step /
operation / payload-case names), the bridged NSError domain + code, the
`FriendlyErrorClass` name, and a boolean. No tokens, keys, session ids, email
addresses, URLs, payloads or user content are logged — the builder
(`PersistedFailureLog.line`) takes an `Error` and never `localizedDescription`;
the queue labels are fixed case names, not entity ids or names. The sign-in
drive used non-account credentials (`992-probe@invalid.example`); nothing about
the attempt is in the log line (domain/code/class only).
