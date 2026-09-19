# #917 — phase-transition termination windows: how the replay converges

This note is the reasoning the committed tests exercise. It documents the
invariant a training-block switch has to end in, the three termination windows,
and the exact replay order that makes a resumed transition converge instead of
duplicating a block.

## The invariant a transition has to end in

`PhaseTransitionPlanner.plan(periods:newPhase:today:)` is the only source of the
mutations. Its end state is: **exactly one open `phase_periods` row, and a
`user_settings` row whose `current_phase`/`phase_start_date` are that period's
phase and start date.**

Two properties of the server make the naive "replay the same requests" wrong:

1. `phase_periods` mints its own row id (`PhaseCreatePayload` carries no id), so
   a create the client never got an answer for can never be recognised by
   identity — only by content (phase + started on).
2. The mutations are a GROUP (close + create + update settings). Process death
   between them leaves a server state that is neither the old block nor the new
   one, and re-planning from THAT state is not always the same plan: a same-day
   switch-back whose `delete` landed but whose `reopen` did not would be
   re-planned as "create a new period today", losing the original start date.

## The intent

`PhaseTransitionIntent` (Sources/Core/DirectWriteReplay.swift) persists, before
the write is presented as accepted:

* the target block and the intended date (`intendedToday`), so a replay weeks
  later reproduces the SAME transition rather than re-planning against a new
  "today",
* `previousPeriods` — the state the plan was authored against,
* `settings` — the row the transition has to end in (the invariant above),
* an `operationID` and `intendedAt`.

It is one queue item (`PhaseTransitionIntent.queueItemID`): an account can only
have one open block, so the newest switch replaces the pending one.

## The replay order (and why each step is where it is)

For one durable intent:

1. **Read the server's own `phase_periods`.**
2. **Already-applied check first.** If exactly one open period carries the
   intended phase AND the intended start date, the transition is materially
   applied — the create landed (or the transition was a no-op). The mutation is
   NOT re-sent: `Update`/`Patch` are idempotent, but `create` is not, and a
   second insert would leave TWO open blocks. Only the settings half is
   completed if the settings row is the half that was lost.
3. **Otherwise re-plan and apply.** The plan input is the intent's own
   pre-state while that view is still anchored on the server's rows (its
   `close`/`reopen`/`updatePhase` targets still exist, and the server has no
   unknown open block); otherwise the server's own state anchors the plan. That
   is what makes a superseded local preview harmless (its period id was never
   minted server-side) while keeping a same-day switch-back's `reopen`.
4. **Completeness check.** The result must leave exactly one open period, of the
   intended phase, with the intended start date. Anything else — no open block,
   the wrong block, two open blocks — throws
   `PhaseTransitionReplayError.incompleteTransition` (classified `retryable`), so
   the intent stays durable and is surfaced as unsynced once the bounded
   attempts run out. It is never confirmed as if the transition had completed.
5. **Settings last.** If the server's settings row is not the intended one, it is
   upserted. The settings write is deliberately last: the periods are the
   authority for what block is open, and a settings row that pointed at a block
   the periods do not show would be the `currentPhase`/history mismatch this
   slice exists to prevent.

Because (2) runs before (3) and (5) runs after (4), the replay is idempotent for
every window: nothing that already landed is sent twice, and nothing that did not
land is left half-applied.

## The three windows against that order

| window | server after the kill | replay | guarded by |
|---|---|---|---|
| before the request | unchanged | plan(pre-state) = the original plan | step 3 (pre-state is server-anchored) |
| between the related writes | partially applied (e.g. old block closed, no new block; the settings row stale) | plan(pre-state) re-derives the same plan; already-applied parts are idempotent PATCHes; the create happens exactly once | step 2 (create) + step 4 (completeness) + step 5 (settings) |
| after server success, before local acknowledgement | fully applied | step 2 short-circuits; only a stale settings row is repaired | step 2 |

## Local settlement (the second half of window 3)

`confirmPhaseTransition` settles the server's answer into the account cache and
the published block:

* every row is revision-fenced against the revisions captured BEFORE the first
  network await; a newer local transition that bumped a row while the request was
  in flight keeps that row (and, when that happens, the older server answer is not
  published over the newer local one at all),
* a local period id the server never minted is retired only when the server's own
  row for it is identifiable by content — otherwise it stays pending, still
  counted as unsynced,
* a pending tombstone the transition's own plan resolved is confirmed instead of
  being counted as unsynced for ever,
* a server row that a newer local tombstone covers is never resurrected.

## Superseded transitions

A second switch while the first is still pending replaces the queued intent
(one transition per account). Its plan is authored from the local preview the
first transition published, so its period targets may reference a local id the
server never minted — step 3's re-anchoring is what turns that into a plan
against rows the server actually owns (`isServerAnchored` = false → the server's
state anchors the plan). The app test
`testOlderTransitionCompletionCannotClearANewerLocalBlock` drives exactly this.

## Residue (pre-#917 rows with no intent)

`recoverLegacyPhaseResidues` resolves only what is provable:

* a live pending row the server already serves with the same content → adopted
  (the optimistic identity is retired, the server row stored),
* a pending tombstone whose identity the server no longer serves → the delete is
  already effective, confirmed,
* the settings row, a per-account singleton upserted by `user_id` → retired when
  the server serves exactly the pending value.

Everything else stays pending and keeps counting as unsynced. Nothing is
reconstructed from a local row alone — there is no per-mutation period writer, so
a period that disagrees with the server cannot be replayed without inventing a
transition, and it is left visible for the user instead.
