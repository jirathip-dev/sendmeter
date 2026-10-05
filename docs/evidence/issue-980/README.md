# #980 — the pre-event credential window (SDK session stored before the model's auth-event loop)

**Verdict: REPRODUCED, then closed at the credential-selection seam.** Full narrative and the
product-answer argument: `.report-980.md` at the lane root.

## What the window is

The SDK stores a new account's session at sign-in **before** `AppModel.handleAuthEvent` processes
that boundary (`authStateChanges` runs serially behind whatever the loop is awaiting). For that
window the SDK's credential source already holds the incoming account's session while
`AppModel.currentUserID` still publishes the outgoing one. The app's account/epoch fences (#933)
gate *publication of completions*; they do not gate **which credentials an in-flight request uses**.
The one token-bearing seam is `AuthService.ensureFreshSession()` (see its own doc comment: "The ONE
token-bearing seam… so the access token is never read off a possibly-expired session").

## The deliberate hold (the run is not the #933 instant-release bug)

`AccountSwitchInFlightAppTests.testAPreEventWindowRetryNeverCarriesTheUnacceptedAccountsBearer`
parks account A's bootstrap request inside `handleAuthEvent(.initialSession) -> refreshAll` and
asserts, at the moment of the switch, that **both holds are still outstanding**
(`bootstrapHold.isOutstanding`, `firstInsert.isOutstanding`; `entered && !delivered`) — an
instantly-released hold (the #933 invalidated run) would fail those assertions. The committed logs
carry an explicit `[#980] window sample:` line with `currentUserID`, the SDK's `sdkSessionUser`,
both hold states, `retryArrived`, `crossed` and `refusedLocally`.

## Artifacts

| File | What it is |
| --- | --- |
| `base-red-focused.log.gz` | **RED receipt** (raw exit 65, final test bytes). `crossed=["GET /rest/v1/tindeq_presets", "POST /rest/v1/tindeq_presets"]`, `retryArrived=true`, `refusedLocally=[]`; assertion lines :510/:530/:550. |
| `green-focused.log.gz` | **GREEN receipt** (raw exit 0, same test bytes, fix applied). `retryArrived=false crossed=[] refusedLocally=["queue-upload:preset"]`; `Executed 1 test, 0 failures`. |
| `probe-1-wiring-removed.diff` | **Mutation probe** (fix → probe): the single `auth.publishedAccountUserIDProvider = …` wiring site removed from `AppModel.swift`. |
| `probe-1-wiring-removed.log.gz` | Probe **RED** (raw exit 65): crossing returns (`crossed=[GET, POST]`, `refusedLocally=[]`) — the regression test bites. |
| `probe-1-restored-green.log.gz` | **Byte-exact restore** GREEN (raw exit 0). `sha256(AppModel.swift)=90da05d0…6540`, `sha256(SupabaseService.swift)=7189eb75…cf7c2` before probe and after restore (recorded below). |
| `app-target-class.log.gz` | `-only-testing:SendmeterNativeTests/AccountSwitchInFlightAppTests` on an erased sim: **9 tests, 0 failures**, raw exit 0. |
| `app-target-full.log.gz` | Full `SendmeterNativeTests` attempt 1: **1 failed** — `CoherentCacheReadAppTests.testAStorageDelayDoesNotStallTheUIActor()` "Test crashed with signal term" (runner termination; no assertion lines). Attribution: that test's transport uses a **fixed** `sessionProvider` (never `ensureFreshSession`), and it passes standalone + in attempt 2. |
| `app-target-full-attempt2.log.gz` | Full `SendmeterNativeTests` attempt 2 on an erased sim: **179 tests, 0 failures**, `** TEST SUCCEEDED **`, raw exit 0. |
| `coherent-cache-standalone.log.gz` | The attempt-1 offender standalone at the same head: **passed (4.786 s)**, raw exit 0. |
| `just-fast.log.gz` | `just fast` raw exit 0 — anti-slop passed; core **1523 / 0**, watch-core **600 / 0**, health-core **70 / 0**. |
| `docs-check.log.gz` | `bash scripts/check-docs-stale-commands.sh` raw exit 0. |
| `check-static.log.gz` | `just check-static` raw exit **1** — pre-existing at base ("Generated project is missing the Force source: ManualForceFullscreen.swift"); not wired into `just ci`. |
| `check-watch-project.log.gz` | `just check-watch-project` raw exit 0 ("generated phone + Watch graph ownership verified"). |
| `git-diff-check.log.gz` | `git diff --check` and `git diff --cached --check` raw exit 0. |
| `SHA256SUMS` | sha256 of every committed file in this directory. |

## Commands (all inside the lane worktree)

```
# RED (base) / GREEN (fix) / probe+restore, focused test:
xcodebuild test -project native/SendmeterNative/SendmeterNative.xcodeproj -scheme SendmeterNative \
  -configuration Debug -destination "id=<impl980-sim UDID>" \
  -only-testing:SendmeterNativeTests/AccountSwitchInFlightAppTests/testAPreEventWindowRetryNeverCarriesTheUnacceptedAccountsBearer \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath <worktree>/.xcode-derived
# class / full:
… -only-testing:SendmeterNativeTests/AccountSwitchInFlightAppTests   (and -only-testing:SendmeterNativeTests)
# host gates:
just fast ; bash scripts/check-docs-stale-commands.sh ; just check-watch-project ; git diff --check
```

House rules honoured: one `xcodebuild` at a time host-wide (`/tmp/sendmeter-xcodebuild.lock` via
the mkdir-lock shim, 45-min stale guard, released on every exit path); worktree-local
`-derivedDataPath`; `xcrun simctl erase` of this lane's own sim before each recorded class/full run
(the app-target suite is a one-run-per-container gate); the sim is shut down afterwards.

## Redaction statement

The committed logs carry **no token or credential material**. The fixture JWT text
(`header.<payload>.signature`) is not present — 0 hits for `header.` — and the committed production
Supabase ref / publishable key do not appear (0 hits for the project ref and for `sb_publishable`).
Requests and credentials are expressed only as **method + path** and as **account UUIDs**, both
generated per-run by the fixtures. Nothing was redacted out of a log after the fact: the harness
never logs bearer text (its `requestSummary` is method+path only), so these logs are unedited.

## Provenance anchors

* RED run at true base: the fix was `git checkout --`-reverted from the two source files; the RED
  receipt was captured with the **final** test bytes (`base-red-focused.log.gz`).
* Restore: `shasum -a 256` of both source files equal to the pre-probe values
  (`90da05d0a196b00d8629875e8f5219d0e97fe3f1e521696e9dc210a8655f6540`,
  `7189eb75c01d73b4ccfb64a2483ab33ba6b4143befa5c3c1a6836c7e079cf7c2`) — see `SHA256SUMS` lineage in
  `.report-980.md`.
