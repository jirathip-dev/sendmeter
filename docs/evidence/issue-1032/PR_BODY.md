## #1032: Dashboard single verdict, sparse trend, copy cleanup, every-tab clearance (rollout #1028 slice 3/3)

Refs #1032, #1022, #1023, #1024

This ports the approved #1028 design round (`fc1d8ada`, `design-output/1028/`) onto current `staging` (`d005404`, with
slices 1 and 2 merged). Nothing from the design branch was merged or cherry-picked wholesale. Full evidence:
`docs/evidence/issue-1032/README.md`.

### What changes

- **#1022, one verdict.** New `Core/DashboardVerdict.swift`: a readiness band (Recover / Maintain / Push) × a load band
  (none / under / optimal / high) maps to one headline plus a load line that is always qualified. All 12 cells have
  copy. "Recover" is never next to an unqualified "Under-training", and the block card no longer repeats the recovery
  advice. The owner's state (readiness 38, ratio 0.66) reads "Recover today — easy movement only." · "Load ratio 0.66 ·
  light week, expected at low readiness".
- **#1023, sparse trend.** Below 5 scored days in 14, the Readiness trend shows "N readiness scores in the last 14 days
  — the trend needs a few more." and a "Check recovery inputs" button. The button opens the **existing**
  `RecoveryInputsSheet` (through the Dashboard's `showRecovery`). No new sheet.
- **#1024 + P10, no implementation prose.** Removed: "Identity dot · tap to arm", "this exercise only · sets, not
  sessions", "…written atomically…", "durably queued" / "durable on-device queue" / "WatchConnectivity" copy. The
  replacements follow the approved #1024 table.
- **F5, every tab.** `sendmeterTabBarEdge` (an opaque edge plus a 14 pt fade under the tab bar) on Dashboard, Workout,
  History and Settings. `TabBarClearanceUITests` gains one iPhone SE case per tab. Slice 2's Force case is unchanged.
- **Force hang fix.** With the shorter empty copy, Force's `LazyVStack`, under slice 2's bottom safe-area bar,
  re-measured forever at the end of the scroll on SE: a 99 % CPU main thread, sampled. Force's scroll stack is now a
  plain `VStack` (about ten cards, so laziness saved nothing). Bisected to that one string, then fixed and green.

### Evidence

- Before/after/approved sheets for each touched state, on iPhone 17 Pro and SE, dark and light:
  `docs/evidence/issue-1032/sheets/`. The README table notes every pixel difference against the approved captures.
- `TabBarClearanceUITests` on SE: 5/5 green (`logs/clearance-se-8.log`, exit 0). Each new tab case has a RED probe
  (exit 65).
- Core RED probes for the verdict table, the sparse-trend wiring and the three removed strings: exit 1, GREEN 0.
- Gates with raw exits: `logs/gates-summary.txt`.

### Not in this PR

- No mascot, imageset, AppModel or DEBUG design-switch change.
- No `DesignFixture1028` or design-round mascot candidates.
- The design branch's `ChartTheme.swift` (staging's palette-token version stays).
