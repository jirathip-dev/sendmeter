# Handoff — #472 hotfix (PR 1 of the plan)

## What changed and why

The watch's auth poll and its two `WCSessionDelegate` callbacks each decided
whether to ask the phone for a fresh token by reading `AuthManager.needsToken`
— a computed property over the **cached** `state` ivar, which is only ever
updated by an explicit event (a relay arriving, `signOutLocally()`, or a call
to `refreshState()`). Once a token relayed fresh went stale by the passage of
time alone, `state` stayed `.signedIn(tokenFresh: true)` forever because
nothing ever re-ran the computation — so all three sites permanently declined
to ask for a new one. This is the repo's #295/#296 defect class (a decision
made from state captured earlier than the decision) in a new spot.

Three files touched:

1. **`ios/App/SendLogWatchCore/Sources/SendLogWatchCore/SessionRelay.swift`**
   — added `SessionRelay.needsToken(for session: RelayedSession?, now:
   TimeInterval) -> Bool`, a pure function (signed-out OR stale-token) that
   is the Core, Linux-testable "should we ask" decision. It always
   recomputes from `session` + `now`, never from a cached `WatchAuthState`.

2. **`ios/App/SendLogWatch Watch App/Services/AuthManager.swift`** — the
   actual fix, at all three sites named in the issue:
   - `refreshState()` (the one function that recomputes `state`) now decides
     whether to call `requestSessionFromPhone()` via
     `SessionRelay.needsToken(for: session, now: now)` — reading the same
     session/now pair it just used to set `state` — instead of reading the
     `needsToken` instance property afterwards.
   - `startPolling()`'s 20 s tick used to `guard let self, self.needsToken
     else { return }` before calling `refreshState()` — i.e. it read the
     cache *before* the one call that could refresh it, so it could never
     recover once the cache went stale. It now calls `self?.refreshState()`
     unconditionally every tick (per the plan: cheap, one pure computation;
     `requestSessionFromPhone()` already self-throttles on `lastRequestAt`).
   - `activationDidCompleteWith` and `sessionReachabilityDidChange` both used
     to do `if self.needsToken { self.requestSessionFromPhone() }` — same
     stale-cache read, and reachability changing is exactly the moment you'd
     want a re-ask to actually fire. Both now call `self.refreshState()`
     instead, which recomputes and self-gates the request.

   `AuthManager.needsToken` (the instance property, still reading `self.state`)
   is untouched and still used by `HomeView.swift:69` for the "waiting for
   iPhone" UI. I deliberately did **not** make that property itself
   clock-derived: `AuthManager` is `@Observable`, and `HomeView`'s body reads
   `auth.needsToken` directly — if that property stopped touching the
   `state` ivar (an actually-tracked stored property) and instead read
   `WatchSessionStore.shared.current` + `Date()` directly, SwiftUI's
   observation tracking would have nothing to subscribe to and the waiting
   screen could stop updating reactively. Routing the *decision* through
   `SessionRelay.needsToken` while leaving the *UI-facing* property alone
   avoids that risk and keeps `state` as the single source of truth for
   display.

3. **`ios/App/SendLogWatchCore/Tests/SendLogWatchCoreTests/SessionRelayTests.swift`**
   — new `SessionRelayStalenessTests`: pins that `SessionRelay.state(for:
   now:)` computed at T disagrees with the same call at T+Δ once the token
   has expired in between (the acceptance criterion's literal ask), plus two
   tests of `needsToken`'s semantics (stale → true, signed-out → true).

4. **`src/lib/watchAuthPollInvariants.test.ts`** (new) — the structural pin
   over `AuthManager.swift`, same shape as `nativeAuthInvariants.test.ts`
   (this file's `AuthManager.swift` is watch-app-target code the `quality`
   job never compiles, and it isn't unit-tested by `swift test` either,
   since `SendLogWatchCoreTests` only covers the pure `SendLogWatchCore`
   package — `AuthManager` itself, with WatchConnectivity and timers, isn't
   pure logic). It extracts each of the three call sites' function bodies by
   brace-counting (robust to reformatting, unlike a line-shaped regex) and
   asserts:
   - `refreshState()`'s body calls `SessionRelay.needsToken(for: session,
     now: now)` and does **not** contain `if needsToken {` (the old
     self-referential cached-property read).
   - `startPolling()`'s body calls `self?.refreshState()` / `self.refreshState()`
     and contains no `needsToken` at all (i.e. the old guard is gone, not
     just reordered).
   - `activationDidCompleteWith` and `sessionReachabilityDidChange` each call
     `self.refreshState()` and contain neither `needsToken` nor
     `requestSessionFromPhone(` directly.
   - `SessionRelay.swift` exposes the `needsToken(for:now:)` signature.

5. **`RELEASE_NOTES.md`** — one line under Unreleased → Fixed. This is
   user-visible: it's the direct fix for the symptom in #470 (long-workout
   live mirror silently freezing).

## Acceptance criteria — verification

- **"A structural test... pins the staleness property — a state computed at
  T must be shown to disagree with `SessionRelay.state(for:now:)` at
  T+delta."** → `SessionRelayStalenessTests.testAStateComputedAtTDisagreesWithTheSameSessionsStateLater`
  in `SessionRelayTests.swift`. Ran green under `swift test` (204/204 passing,
  up from 201 before this change — 3 new tests).

- **"Plus proof the production paths route through the new decision... A
  test of the new helper alone is NOT acceptable."** →
  `src/lib/watchAuthPollInvariants.test.ts`. I verified this fails on the
  pre-fix source, not just that it passes now: I `git stash`ed the two
  Swift-source changes (keeping the new test file) and re-ran
  `npx vitest run src/lib/watchAuthPollInvariants.test.ts` — **5 of 6
  assertions failed** against the original code (only the "finds the file"
  smoke check passed). The failures were exactly the ones you'd expect:
  `startPolling()`'s body still contained `needsToken` (the old guard),
  `activationDidCompleteWith`'s and `sessionReachabilityDidChange`'s bodies
  didn't call `refreshState()` at all. I then `git stash pop`ped to restore
  the fix and confirmed all 6 pass again. This is the "fails before, passes
  after" proof the brief requires — I did not rely on reasoning alone.

- **"Existing `SessionRelayTests` must stay green."** → Yes, all pre-existing
  tests in that file are unmodified and still pass (verified in the same
  `swift test` run, 204/204).

- **Three guard sites, all fixed.** `AuthManager.swift:218` (poll — now
  unconditional `refreshState()`), `:233` → now inside `refreshState()`'s call
  at the activation callback, `:254` → same at the reachability callback. Line
  numbers shifted slightly from the doc-comment additions; the diff in this
  handoff shows the exact before/after.

- **Throttle name.** Untouched — `requestSessionFromPhone` still throttles on
  `lastRequestAt` via `SessionRelay.shouldRequestRelay(now:lastRequestAt:)`,
  confirmed by reading the current source before editing. Nothing in this
  change touches `lastRelayAt`.

## Validation run

- `cd ios/App/SendLogWatchCore && swift test` — 204/204 passed.
- `npm run typecheck && npm run lint && npm test && npm run build` — all
  green (`npm test` = 93 files / 1281 tests passed, including the new
  structural test file).
- `xcodebuild build -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" -destination "generic/platform=watchOS Simulator" CODE_SIGNING_ALLOWED=NO`
  — `** BUILD SUCCEEDED **`.

## Explicitly out of scope (per the brief, not touched)

- `OfflineQueue`'s retry/classifier (#475's error taxonomy is a prerequisite;
  deferred to PR 3 per the plan).
- Pre-emptive relay (the phone's `getSession()` can hand back the same
  still-valid token, so it wouldn't accomplish anything — deferred, may be
  cut).
- `SessionRelay.freshnessMarginS` — untouched. It still gates both `decode`
  and the new `needsToken`/existing `isFresh`, as required.
- The one-off prod fix for the stuck `live_workouts` row — not run from this
  branch; it's a deliberate manual action per the plan, predicated on
  `workout_id` + `status='live'` + `updated_at`.

## Things I'm not fully certain about

- **Device verification is not possible from here.** This fix cannot be
  exercised end-to-end (a real >60 min foreground workout re-relaying
  mid-session) outside TestFlight/device, per the plan's own acceptance note
  ("device/TestFlight-only, flag as pending"). I'm flagging it as such, not
  claiming it.
- **UI staleness surfacing latency.** With this fix, `HomeView`'s "waiting for
  iPhone" state now becomes reachable via the 20 s poll (previously it could
  never trigger from staleness alone). I did not add a dedicated test that
  `HomeView` re-renders when `state` flips via the poll — this would need a
  SwiftUI test harness for `AuthManager`, which doesn't exist in this repo and
  felt out of scope for a hotfix branch focused on the decision logic itself.
  If the reviewer wants stronger proof here, the honest gap is: I've proven
  `refreshState()` is called and that it sets `state` correctly (existing
  `SessionRelayTests` cover the state mapping); I have not proven SwiftUI
  actually redraws `HomeView` in response, though nothing in this change
  alters how `state` is published (`@Observable`, `private(set) var state`),
  so I don't believe this diff introduces a new risk there — it's an existing,
  untested-either-way property of the view layer.
- **`SessionRelay.needsToken` duplicates `AuthManager.needsToken`'s switch
  logic** (one over a live session/clock, one over cached `state`). I
  considered collapsing them (e.g. have the instance property call
  `SessionRelay.needsToken(for: WatchSessionStore.shared.current, now: now)`
  directly) but rejected it for the `@Observable`/SwiftUI-tracking reason
  explained above. Flagging the duplication in case the reviewer sees a
  cleaner seam I didn't.
