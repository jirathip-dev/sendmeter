# #1039 — developer-text inventory (stage 1, for owner approval)

Swept at `staging` @ `8ed4a06`. **No app code changed.** Stage 2 (the copy
edits + the denylist gate) starts only after the owner approves this table.

Path prefixes: **P** = `native/SendmeterNative/Sources/`,
**W** = `ios/App/SendLogWatch Watch App/`,
**WC** = `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/`.

Actions: **remove** (text goes, nothing replaces it) · **rewrite** (new copy
given) · **keep** (already in user words, or it prevents a real mistake) ·
**#1038** (already proposed in #1038 — HP4/HP9/P10; listed so nothing is
missed, not to be done twice).

How the sweep was done: every string literal in phone app, phone widgets,
Watch app, Watch widgets and the shared Core/WatchCore copy files was grepped
for storage/sync/implementation vocabulary (immutable, metadata, stored,
linked, sync, queue, server, upload, relay, durable, cache, raw, samples,
armed, context, …), plus every section header/eyebrow/navigation title and
every literal over 55 characters (captions, footers, empty states, hints).
Logger/`os_log` lines, `accessibilityIdentifier`s, DB/URL keys and error
details shown only in Settings → technical details were excluded (see
"Exempt" at the end).

---

## 1. History → force recording editor (owner screenshot)

| # | Current string | Location | Action | New copy |
|---|---|---|---|---|
| 1.1 | "Metadata" (section header) | P `Features/History/HistoryView.swift:998` | rewrite | "Details" |
| 1.2 | "RPE is stored on the linked session and changing it confirms the effort review." | P `Features/History/HistoryView.swift:1026` | remove | — (the "Session effort" header + RPE slider already say it) |
| 1.3 | "Raw force samples are immutable; this editor changes metadata only." (lock label) | P `Features/History/HistoryView.swift:1031` | rewrite | "The pull itself can't be edited." |
| 1.4 | "\(n) samples" (recording row + editor) | P `Features/History/HistoryView.swift:833`, `:972` | remove | — (sample count means nothing to a climber; duration/peak already shown) |
| 1.5 | "No trace samples are available for this recording." | P `Features/History/HistoryView.swift:981` | rewrite | "No force curve for this pull." |
| 1.6 | "Historical sessions keep the block they were logged under." | P `Features/History/HistoryView.swift:912` | remove | — |
| 1.7 | "The earliest session keeps the entry; the others move into it." (merge sheet) | P `Features/History/HistoryView.swift:1378` | keep | (prevents a wrong merge; already user words) |

## 2. History → uploads banner

| # | Current string | Location | Action | New copy |
|---|---|---|---|---|
| 2.1 | "Uploads waiting" / "Rejected uploads" (title) | P `Features/History/HistoryView.swift:591`, `:594`, `:596` | rewrite | "Not saved to your account yet" / "Couldn't save" |
| 2.2 | "\(n) queued on this iPhone" | P `Features/History/HistoryView.swift:606` | rewrite | "\(n) on this iPhone" |
| 2.3 | "The server rejected these; they are kept on this device and never retried on their own — manage them in Settings." | P `Features/History/HistoryView.swift:612` | rewrite | "Sendmeter couldn't save these. They're still on this iPhone — open Settings to retry or discard them." |
| 2.4 | "… Queued data is durable on device and retries automatically; rejected items never retry on their own — manage them in Settings." | P `Features/History/HistoryView.swift:614` | rewrite | "… They'll save automatically when you're back online." |
| 2.5 | "The last upload attempt failed." / "Last attempt (\(class)): \(reason) The app will retry automatically; use Retry Now in Settings if needed." | P `Features/History/HistoryView.swift:621-622` | rewrite | drop the "(\(class))" label and the retry explanation; keep just "\(reason)" |
| 2.6 | "Sync once to bring your training story back into view." (empty state) | P `Features/History/HistoryView.swift:113` | rewrite | "Pull to refresh to load your history." |

## 3. Force tab

| # | Current string | Location | Action | New copy |
|---|---|---|---|---|
| 3.1 | "Recording context" (eyebrow) | P `Features/Force/ForceRecordingContextCard.swift:136` | remove | — (the movement/side values under it are the content) |
| 3.2 | "RECORDING CONTEXT" (picker eyebrow) | P `Features/Force/ForceRecordingContextCard.swift:1238` | #1038 (HP9) → remove | — ("Movement & side" title stays) |
| 3.3 | "Updates instantly" | P `Features/Force/ForceRecordingContextCard.swift:1246` | #1038 (HP4) → remove | — |
| 3.4 | "Armed now · no confirmation step" | P `Core/ForceBarPolicy.swift:291` | #1038 (P10) → rewrite | "Pull to start" |
| 3.5 | "Arm from the bar below" | P `Core/ForceBarPolicy.swift:290` | keep | (tells the user where the control is) |
| 3.6 | "Resolving the protocol target from this exercise's force history…" | P `Features/Force/ForceView.swift:3176` | rewrite | "Setting your target…" |
| 3.7 | "Each set resolves against the exercise's Hill force-duration curve at that set's prescribed work duration." (protocol editor footer) | P `Features/Force/ForceView.swift:3874` | rewrite | "Each set's target comes from your force curve." |
| 3.8 | "Alternation applies when you record Both sides; a Left or Right selection runs that side only." | P `Features/Force/ForceView.swift:3821` | keep | (prevents a wrong-side protocol) |
| 3.9 | "Saves this protocol into the live gauge session and returns to the Force tab" (a11y hint) | P `Features/Force/ForceView.swift:1093` | rewrite | "Saves this protocol and returns to the Force tab" |
| 3.10 | "This pull still isn't in the durable queue. Discard it below if you don't need it — it can't be recovered after that." | P `Core/ForceLaunchRecovery.swift:201` | rewrite | "This pull hasn't been saved yet. Discard it if you don't need it — it can't be recovered after that." |
| 3.11 | "The protocol has already ended, so there is nothing left to resume or end — but its session still holds the screen. Clearing it releases this screen; nothing you recorded, queued, or left unsaved is deleted." | P `Core/ForceLockRecovery.swift:80` | rewrite | "This protocol has ended. Clearing it frees the screen — nothing you recorded is deleted." |
| 3.12 | "A finished guided protocol is holding this screen" | P `Core/ForceLockRecovery.swift:79` | rewrite | "This protocol has ended" |
| 3.13 | "No force samples were received." (refusal toast) | P `Features/Force/ForceView.swift:2471` | rewrite | "No pull was detected." |
| 3.14 | "Peak force for each measured static hold in this evidence set." (+ target variant) (VoiceOver chart summary) | P `Features/Force/ForceTrendChart.swift:301`, `:306` | rewrite | "Peak force for each measured static hold." |
| 3.15 | "Movement is tracked as execution quality. It never changes your Static PR, Hill/CF model or asymmetry." | P `Features/Force/MovementDetailView.swift:59` | rewrite | "Movement sets don't change your Static PR, force curve or asymmetry." |

## 4. Force → Training balance detail

| # | Current string | Location | Action | New copy |
|---|---|---|---|---|
| 4.1 | "History lists every session … the two are expected to disagree, and neither is wrong." | P `Features/Force/TrainingBalanceDetailView.swift:94` | remove | — |
| 4.2 | "None of these holds store the zone they were performed under, so every one is bucketed by how long it lasted. Only holds recorded under an armed zone or preset carry the real thing." | P `Features/Force/TrainingBalanceDetailView.swift:104` | rewrite | "These holds are sorted into zones by how long they lasted." |
| 4.3 | "\(recorded) of \(n) holds store the zone they were performed under and are counted as that; …" | P `Features/Force/TrainingBalanceDetailView.swift:106` | rewrite | "\(recorded) of \(n) holds were recorded with a zone; the rest are sorted by how long they lasted." |
| 4.4 | `zoneBandCaveat` ("A hold recorded under an armed zone or preset stores the zone … anything saved before this app stored it … inherently fuzzy …") under "How a hold gets its zone" | P `Core/ZoneMix.swift:552` (shown at `TrainingBalanceDetailView.swift:256`) | rewrite | "Holds recorded with a zone or preset count toward that zone. Other holds are sorted by length, so short holds near a boundary may count partly toward the next zone." |
| 4.5 | "No critical-force fit yet, so the force curve had no say — the least-trained zone stands on its own." | P `Features/Force/TrainingBalanceDetailView.swift:144` | rewrite | "Showing your least-trained zone." |

## 5. Workout tab

| # | Current string | Location | Action | New copy |
|---|---|---|---|---|
| 5.1 | "Server mirror" / "Mirror" (live-workout transport label) | P `Features/Workout/WorkoutView.swift:556`, `:558` | rewrite | "Live" (both) |
| 5.2 | "Link paused" | P `Features/Workout/WorkoutView.swift:557` | rewrite | "Reconnecting…" |

## 6. Dashboard + widgets

| # | Current string | Location | Action | New copy |
|---|---|---|---|---|
| 6.1 | "The raw HealthKit metrics your daily readiness score is computed from." | P `Features/Dashboard/RecoveryInputsSheet.swift:46`, `:178` | remove | — (title "Recovery Inputs" says it) |
| 6.2 | "Shows the raw HealthKit metrics behind today's readiness score." (a11y hint) | P `Features/Dashboard/DashboardView.swift:281` | rewrite | "Shows the Apple Health data behind today's readiness score." |
| 6.3 | "Sync once to bring your recent sends back into view." | P `Features/Dashboard/DashboardView.swift:425` | rewrite | "Pull to refresh to load recent sessions." |
| 6.4 | "Sync once to bring your ACWR forecast back into view." | P `Features/Dashboard/AcwrProjectionCard.swift:102` | rewrite | "Pull to refresh to load your forecast." |
| 6.5 | "Your most recent sessions fall outside the 90-day window this card projects from, so there's no ACWR ratio to extend yet — log a session …" | P `Features/Dashboard/AcwrProjectionCard.swift:118` | rewrite | "No sessions in the last 90 days. Log one to see your forecast." |
| 6.6 | "Syncing" / "Rejected" (recent-session pill) | P `Features/Dashboard/DashboardView.swift:468` | rewrite | "Saving…" / "Not saved" |
| 6.7 | Widget "…open Sendmeter to sync today's score/readiness." (5 variants) | P `Widgets/ReadinessWidget.swift:112`, `:121`, `:136-137`, `:148-149`, `:223`, `:232` | keep | ("sync" here is a user action, not an internal) |
| 6.8 | ACWR explainer sheet ("session-RPE method", "exponentially-weighted moving averages") | P `Features/Dashboard/AcwrStatusCard.swift:284-296` | keep | (opt-in "How ACWR is calculated" sheet — the user asked for it) |

## 7. Settings

| # | Current string | Location | Action | New copy |
|---|---|---|---|---|
| 7.1 | "Data sync" (subheader) | P `Features/Settings/SettingsView.swift:574` | rewrite | "Saving" |
| 7.2 | "Pending uploads" / "Upload status" (row + a11y) | P `Features/Settings/SettingsView.swift:576`, `:582` | rewrite | "Not saved yet" / "Save status" |
| 7.3 | "Synced" / "\(n) waiting to upload" | P `Core/MutationSyncStatus.swift:193`, `:195` | rewrite | "All saved" / "\(n) not saved yet" |
| 7.4 | "Checking this iPhone's pending changes and uploads." | P `Core/MutationSyncStatus.swift:207` | rewrite | "Checking…" |
| 7.5 | "Every change on this iPhone has been confirmed by the server." | P `Core/MutationSyncStatus.swift:209` | remove | — (the "All saved" pill says it) |
| 7.6 | "\(n) local changes saved on this iPhone, plus \(n) queued uploads kept here. Nothing has been dropped; uploads retry automatically." (+ 2 variants) | P `Core/MutationSyncStatus.swift:218-226` | rewrite | "\(n) changes are on this iPhone and will save automatically." / "… Tap Retry Now to save them." |
| 7.7 | "The server rejected \(n) changes. They are kept on this device and never retried on their own — retry or discard them below." | P `Core/MutationSyncStatus.swift:231` | rewrite | "Sendmeter couldn't save \(n) changes. Retry or discard them below." |
| 7.8 | "\(n) local changes could not be uploaded and stayed on this iPhone. The server's answer never confirmed them." | P `Core/MutationSyncStatus.swift:233` | rewrite | "\(n) changes couldn't be saved. They're still on this iPhone." |
| 7.9 | "Retrying cannot move these changes: this app version has no upload path for them, so they stay on this iPhone until they are re-saved." | P `Core/MutationSyncStatus.swift:244` | rewrite | "Update Sendmeter to save these changes." |
| 7.10 | "Rejected uploads" (row) + "The server rejected these permanently. They are kept on this device and never retried on their own; retry them by hand if you believe they should upload now, or discard them." | P `Features/Settings/SettingsView.swift:677`, `:682`, `:686`, `:710` | rewrite | "Couldn't save" + "Retry or discard these." |
| 7.11 | "This permanently deletes the unsynced \(kind) from this device. The server never received it, so it cannot be recovered afterward." | P `Features/Settings/SettingsView.swift:101` | rewrite | "This permanently deletes this \(kind). It was never saved to your account, so it can't be recovered." |
| 7.12 | "\(n) recordings not uploaded" + "It's still waiting to reach the server — usually that means no connection. Signing out keeps it on this device; it uploads the next time this account signs in." (sign-out alert, 2 variants) | P `Features/Settings/SettingsView.swift:163`, `:169-170` | rewrite | "\(n) recordings not saved yet" + "Signing out keeps them on this iPhone; they'll save next time you sign in." (keep — prevents a data-loss surprise) |
| 7.13 | "Last \(kind) attempt: \(reason) The app will retry automatically; use Retry Now if needed." / "The last upload attempt failed." | P `Features/Settings/SettingsView.swift:560-561` | rewrite | "\(reason)" |
| 7.14 | "Waiting to upload" (Watch row value) | P `Features/Settings/SettingsView.swift:337` | rewrite | "Waiting on watch" |
| 7.15 | "Sets aside anything on this iPhone that Sendmeter can't read and rebuilds it from your account. Anything that hasn't synced yet is never touched." (Repair local data footer) | P `Features/Settings/SettingsView.swift:662` | rewrite | "Reloads your data from your account. Unsaved changes are kept." ; button "Repair local data" → "Repair data" |
| 7.16 | "Metric (kg) or Imperial (lb). Applies to body weight; Force and load units come later." | P `Features/Settings/SettingsView.swift:183` | rewrite | "Applies to body weight." |
| 7.17 | "System follows the device appearance. The choice is applied on launch." | P `Features/Settings/SettingsView.swift:196` | remove | — |
| 7.18 | "Read HRV, resting heart rate, sleep, respiratory rate, and body mass to compute daily readiness on device." | P `Features/Settings/SettingsView.swift:281` | keep | (privacy disclosure for the Health permission) |
| 7.19 | "The last Apple Health refresh failed; the previous reading is kept." | P `Features/Settings/SettingsView.swift:297` | rewrite | "Couldn't refresh Apple Health. Showing your last reading." |
| 7.20 | "Not uploaded yet" / "… can't be uploaded by this app version." / "… on this iPhone — checking whether the server has them." / "… saved on this iPhone and not uploaded yet." (Manage Exercises) | P `Features/Settings/TagManagerView.swift:92`, `:99`, `:103`, `:105` | rewrite | "Not saved yet" / "Update Sendmeter to save these." / "Checking…" / "\(n) changes not saved yet." |
| 7.21 | "Rename updates every recording with that exercise. Hiding keeps the data but drops the exercise from the pickers." | P `Features/Settings/TagManagerView.swift:36` | keep | (prevents an unexpected bulk rename) |
| 7.22 | Delete Account: "…every piece of data stored for it on the server…", "Uploads still waiting for this account are removed only after the server confirms account deletion.", "…all server data…" | P `Features/Settings/SettingsView.swift:974`, `:1043`, `:1045`, `:1116`, `:1130` | rewrite | "…all of your data…"; drop the 1045 sentence |

## 8. Watch

| # | Current string | Location | Action | New copy |
|---|---|---|---|---|
| 8.1 | "Quarantined uploads" (home row + nav title) / "Uploads the server has stopped accepting" / hint "Shows uploads taken off the retry path" | W `Views/HomeView.swift:530`, `:532`, `:547`; `Views/QuarantineDiagnosticsView.swift:88` | rewrite | "Couldn't save" / "Tap to retry" / "Shows saves that need a retry" |
| 8.2 | "Off the upload path" (eyebrow) | W `Views/QuarantineDiagnosticsView.swift:243` | remove | — |
| 8.3 | "No quarantined uploads" / "Everything is on the ordinary upload path." / "No quarantined uploads are stored on this watch." | W `Views/QuarantineDiagnosticsView.swift:246`, `:248`, `:307` | rewrite | "Everything is saved" ; remove the second line |
| 8.4 | "\(n) uploads set aside" / "\(n) uploads left quarantine" / "\(n) will not retry" | W `Views/QuarantineDiagnosticsView.swift:252`, `:167`, `:292` | rewrite | "\(n) not saved" / "\(n) saved since" / "\(n) can't be saved" |
| 8.5 | "The queues haven't been counted yet. Refresh this screen to read them." / "The retry breakdown hasn't been reported yet." | W `Views/QuarantineDiagnosticsView.swift:265`, `:284` | rewrite | "Checking…" (both) |
| 8.6 | "Legacy uploads need review" + "\(n) watch items have no account stamp. They are retained here but will not upload until an explicit recovery p…" | W `Views/QuarantineDiagnosticsView.swift:50-51` | rewrite | "Older saves need review" + "\(n) saves from an earlier version can't be matched to an account." |
| 8.7 | "The record can't be read by this build. It is kept on the watch (#287); a newer build may be able to recover it." | W `Views/QuarantineDiagnosticsView.swift:336` | rewrite | "This save can't be read. Update Sendmeter to try again." (drop the issue number) |
| 8.8 | "Tries the retryable uploads again now instead of waiting for the automatic retry" (hint) | W `Views/QuarantineDiagnosticsView.swift:231` | rewrite | "Tries these saves again now" |
| 8.9 | "Could not be uploaded — will not retry" / "Having trouble uploading — retrying automatically" | WC `QuarantineDiagnostics.swift:75`, `:77` | rewrite | "Can't be saved" / "Trying to save…" |
| 8.10 | "The server permanently rejected this upload. It stays saved on your watch; retrying it won't help." | WC `QuarantineDiagnostics.swift:84` | rewrite | "Sendmeter can't save this. It stays on your watch." |
| 8.11 | "It gets one automatic retry in a few days. You can also retry it now." | WC `QuarantineDiagnostics.swift:86` | rewrite | "Sendmeter will try again later, or retry it now." |
| 8.12 | "Some detail was dropped at quarantine — a retry uploads its summary, not the original buffer." | WC `QuarantineDiagnostics.swift:94` | rewrite | "Only the summary of this one can be saved; its force curve is gone." |
| 8.13 | "Retry stuck uploads" / "Moves retryable uploads back to the upload queue and tries them now." / "\(n) uploads moved back to the queue" | WC `QuarantineDiagnostics.swift:128`, `:131`, `:142` | rewrite | "Retry" / remove / "\(n) retrying" |
| 8.14 | "Your new rep was saved. Storage was full, so an older recording the server kept rejecting gave up its stored force curve — its summary numbers remain." | W `Views/HomeView.swift:77` | rewrite | "Your new rep was saved. Watch storage was full, so an older recording kept its numbers but lost its force curve." |
| 8.15 | "A recording couldn't be saved to your watch or uploaded. It's gone — the rest of your session is unaffected." | W `Views/HomeView.swift:75` | rewrite | "A recording couldn't be saved. The rest of your session is fine." |
| 8.16 | "\(n) uploads waiting" + "Saved on the watch; they upload when your iPhone is in range." / "Syncing uploads" / "Offline saves" / "Pending uploads stay on the watch until the connection recovers." / "New saves upload once it is in range." | W `Views/HomeView.swift:557-558`, `:565`, `:580`, `:596` | rewrite | "\(n) waiting for iPhone" + "They'll save when your iPhone is nearby." / "Saving…" / "Saved on watch" / remove 596 / "They'll save when it's nearby." |
| 8.17 | "\(n) saves waiting" + "They upload when your iPhone signs this watch in." | W `Views/WaitingForPhoneView.swift:63-64` | rewrite | "They'll save once you sign in on your iPhone." |
| 8.18 | "Open Sendmeter on your iPhone. This watch uses its session — there is no separate watch login." | W `Views/WaitingForPhoneView.swift:82` | rewrite | "Open Sendmeter on your iPhone to sign in." |
| 8.19 | "Could not use that relay" | W `Views/WaitingForPhoneView.swift:100` | rewrite | "Couldn't sign in" |
| 8.20 | "Cached" / "Cached (\(date))" / "Cached · afternoon freeze" / "Offline · showing cached" / "Refresh failed · showing cached" (readiness status) | W `Services/ReadinessManager.swift:82`, `:165`, `:265`, `:271`, `:273`, `:277`; `Views/StatusView.swift:39`, `:60`; WC `WatchDesign.swift:189` | rewrite | "Last update" / "From \(date)" / "Today's score" / "Offline · last score" / "Couldn't refresh · last score" |
| 8.21 | "Progressor disconnected · force recovery queued" / "… partial hold recovered and queued" | W `Services/GuidedForceRunner.swift:478`, `:486` | rewrite | "Progressor disconnected · pull saved" / "… partial hold saved" |
| 8.22 | "Your workout stays on the watch until a retry succeeds." | W `Views/WorkoutLiveView.swift:111` | rewrite | "Your workout is safe on the watch. Try saving again." |
| 8.23 | "Free hold · armed" / "Armed — pull to start" / a11y "Free hold, armed" | W `Views/ForceGaugeView.swift:86`, `:999`, `:1002` | #1038 (P10 family) | defer to #1038's outcome |
| 8.24 | "Run this alternating-sides protocol on your iPhone; alternating sides are unsupported on watch" (hint) | W `Views/ForceGaugeView.swift:1098` | rewrite | "Run this protocol on your iPhone." |
| 8.25 | "Syncing protocols…" / "Couldn't sync protocols" | W `Services/ForceProtocolCatalog.swift:78`; WC `ForceProtocolSyncCopy.swift:59` | keep | (short, user-level) |

---

## Exempt (not user copy — the stage-2 gate must skip these)

- Settings → **technical details** (`SettingsView.swift:773-880`: "User ID",
  "Rejected-upload diagnostics", "Queued-upload diagnostics", "Server code",
  "Class", "Attempts", "Next retry", "Auth events"). Opt-in support surface by
  design (#758 AC 3). Proposed: keep as is.
- `Logger` / `os_log` / `recordAuthEvent` / `record*Failure` detail strings,
  `NSError` descriptions, `accessibilityIdentifier`s, DB column / URL /
  UserDefaults / file names. `FriendlyError.swift:243` ("server rejection")
  and `:256-260` ("Pending upload deleted", "Rejected upload discarded") are
  classification labels — stage 2 must confirm where they render before
  exempting them (not traced in this sweep).
- Code comments.

## Stage-2 gate proposal (after approval)

A source-text test in the `SendmeterCore` suite (same style as the existing
wiring tests) that scans string literals inside `Text(`, `Label(`,
`SectionLabel(`, `*Eyebrow(`, `.accessibilityLabel/Hint(`, `message:`,
`title:` and the copy files above, phone + Watch, and fails on:
`immutable`, `metadata`, `atomically`, `linked session`, `durable`,
`quarantine`, `upload path`, `relay`, `server`, `cache`/`cached`, `raw `,
`samples`, `queue`/`queued`. Exempt list = the section above, by file:line
range.

## Open questions for the owner

1. Is "save / not saved yet" the right user word for what the app today calls
   upload / sync? (It drives ~40 rows above.)
2. Watch quarantine screen (8.1-8.13): rename as proposed, or fold it away
   entirely behind Settings on the phone?
3. Training balance (4.x) and ACWR explainer (6.8): those are opt-in "how it
   works" screens — trim as proposed, or keep the long form there?
