# Sendmeter — native design contract

**Status: current.** This document describes the shipped **native** product
(SwiftUI iPhone app, Apple Watch app + complications, and the readiness
widget). It replaces the retired **web/Capacitor design spec** that lived at
this path until #930; the retired material is kept only as a clearly marked
[historical section](#historical-retired-webcapacitor-design-spec-pre-857), and
its CSS/font/chrome guidance is **not** current instruction.

No code, token, asset or behavior is defined here for the first time. This is a
descriptive contract: every rule cites the live Swift symbol or file that
already owns it.

## How to read this document

- **Descriptive rules** — already true at the cited `file:line`; a change to
  the code without this document is a doc bug, and a change to the document
  without the code is not a design change.
- **Future acceptance** — work that is routed or proposed but not yet in the
  tree; each item names its owning slice (U01/U02/U03, #928/#929) rather than
  inventing a second owner.
- **Decisions** — open or owner-recorded choices. Nothing here authorizes a
  visual change; see [Decisions and open items](#decisions-and-open-items).
- **Frozen** — approved geometry that may not drift (mascots, the splash
  composite); see [Approved artwork geometry](#approved-artwork-geometry-frozen).

Document owner: the native app's design system sources below. Change discipline:
edits to this file are checked by
[`scripts/check-design-contract.sh`](#how-this-document-is-checked).

## Platform surfaces

| Surface | Product | Entry / owner |
|---|---|---|
| iPhone app | every product screen | `native/SendmeterNative/Sources/App/SendmeterNativeApp.swift`, `Sources/Features/**` |
| Apple Watch app | glanceable status, workout, force | `ios/App/SendLogWatch Watch App/**`, pure contracts in `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/WatchDesign.swift` |
| Watch complications / widgets | status, live workout | `ios/App/SendLogWatchWidgets/StatusColors.swift` (band colors) and `ios/App/SendLogWatchWidgets/StatusVisuals.swift` (visuals) |
| iPhone widget | today's readiness | `native/SendmeterNative/Sources/Widgets/ReadinessWidget.swift` |

The web app, root npm package and the Capacitor iOS host were retired in #857
(`docs/architecture/857-removal-inventory.md`). There is no web design surface.

## Semantic color ownership

**One hue source, per-surface adaptation.** The canonical semantic hues live in
`SendmeterSemanticHue` (`ios/App/SendLogWatchCore/Sources/SendLogWatchCore/WatchDesign.swift:10-26`)
and are consumed by every surface:

| Semantic | Hex | Meaning |
|---|---|---|
| `primary` | `#5B5FC7` | interaction accent, live force trace, focus/data series |
| `optimal` | `#2E96F0` | readiness Push, optimal ACWR, in-zone force, positive/complete state |
| `caution` | `#DDB13A` | readiness Maintain, ACWR caution, pending/queued work |
| `danger` | `#E5743A` | readiness Recover, ACWR danger, refused/failed work |
| `execution` | `#7B83EB` | Execution phase identity, power-endurance quality |

Owners by surface:

- **Phone** — `SendmeterStyle` (`native/SendmeterNative/Sources/App/DesignSystem.swift:25-54`)
  exposes the hues as `Color` (`capacity`=optimal, `strength`=caution,
  `power`=danger, `execution`, `primary`, `optimal`, `caution`, `alert`,
  `paused`). Phase identity: `SendmeterStyle.phaseColor(_:)`; training-quality
  badges: `zoneColor(_:)` (`DesignSystem.swift:35-54`).
- **Charts** — `ChartToken`
  (`native/SendmeterNative/Sources/App/ChartTheme.swift:13-220`) resolves
  semantic light hexes from the canonical hues and keeps the **dark-mode pairs**
  as the phone's own adaptation (`ChartTheme.swift:193-212`), plus per-activity
  hues in `ChartActivityHue` (`ChartTheme.swift:246-296`).
- **Widget** — `ReadinessWidgetSemanticToken`
  (`native-plugins/sendlog-health-core/Sources/SendLogHealthCore/ReadinessWidgetContract.swift:225-254`)
  keeps the light/dark hex pairs in the shared Foundation-only module so the
  widget process and the Dashboard cannot drift; bands map onto it in
  `ReadinessWidgetReadinessBand` / `ReadinessWidgetACWRBand`
  (`ReadinessWidgetContract.swift:256-289`).
- **Watch** — `WatchDesignTokens`
  (`WatchDesign.swift:32-160`): the four semantic accents resolve from the
  canonical hues; `success` is the watch-native green (`WatchDesign.swift:67`)
  used only for completion, and `force` (`#FF6EC2`) is the Home screen's
  Force-module nav-card identity only (`WatchDesign.swift:70-82`).
- **Watch complications** — `ios/App/SendLogWatchWidgets/StatusColors.swift:8-64`
  reads the same Core palette; ACWR/readiness maps onto
  primary/secondary/warning/danger.

### Health semantics (resolved against the native implementation)

- The health scale runs **cool → warm**: optimal/complete `#2E96F0` → caution
  `#DDB13A` → alert `#E5743A`. There is **no red**, and green is not a health
  signal on the phone (the web-era success/danger health colors are not phone
  semantics).
- The **in-zone force state is `optimal` blue**, not green: the live card
  switches the metric to `SendmeterStyle.optimal` when the current value is
  inside the target range (`Sources/Features/Force/ForceView.swift:2662-2666`,
  `inTarget` at `ForceView.swift:3002-3003`), and the chart's target band is
  drawn in `ChartToken.optimal` (`Sources/Features/Force/NativeForceCurveCard.swift:344-373`).
- **Purple is still interaction + live data**, not a health signal: it carries
  the live trace and focus series (`ChartToken.focus`/`.force`).
- **Dark mode**: chart tokens carry explicit dark pairs
  (`ChartTheme.swift:199-212`); the Force trace's target band is raised in dark
  mode to the least opacity that clears the non-text contrast floor
  (`ChartTheme.swift:55-72`), and its grid uses the `axis` token
  (`ChartTheme.swift:74-84`).
- **Appearance**: System / Light / Dark is stored in `AppTheme` and applied
  pre-paint through `AppThemeController.resolvedScheme(prefersDark:)`
  (`native/SendmeterNative/Sources/App/AppThemeController.swift:11-30`).

## Typography and Dynamic Type

System fonts only (SF, `.rounded` for metric values); digits are
`monospacedDigit()` wherever numbers stack or align. There is no fixed px type
scale — the retired web type ramp is gone; sizes are Dynamic-Type-relative.

| Role | Symbol | Rule | Source |
|---|---|---|---|
| Hero metric | `HeroMetricModifier` | `.system(.largeTitle, design: .rounded).weight(.bold)`, `monospacedDigit`, `allowsTightening`, `lineLimit(1)`, `minimumScaleFactor(0.65)` | `DesignSystem.swift:57-68` |
| Countdown metric | `CountdownMetricModifier` | `@ScaledMetric(relativeTo: .largeTitle)` seeded from the caller's context size, `minimumScaleFactor(0.55)` | `DesignSystem.swift:70-85` |
| Section label | `SectionLabel` | `.caption2.weight(.semibold)`, uppercased, `tracking(1)`, `.secondary` | `DesignSystem.swift:271-289` |
| Metric + unit | `MetricValue` | hero value + `.subheadline.weight(.semibold)` unit via `ViewThatFits` (inline, then stacked) | `DesignSystem.swift:291-338` |
| Chart axis label | `ChartAxisLabelRule.font` | `.caption2.monospacedDigit()` | `ChartTheme.swift:222-239` |
| Widget metric | `@ScaledMetric(relativeTo: .largeTitle/.title)` (39/30 base) | scales with the user's text size | `ReadinessWidget.swift:94-95` |

Metric values never wrap: `lineLimit(1)` + a scale factor is the contract, so a
long reading shrinks instead of reflowing the card. Chart labels do the
opposite — they keep their text style and **thin the ticks** (below).

## Hierarchy: cards, labels, actions

- **Card** — `SurfaceCard` (`DesignSystem.swift:139-162`): content padded by
  `SendmeterStyle.spacing` (16 pt), full width, `.regularMaterial` background in
  a continuous rounded rectangle at `SendmeterStyle.radius`, with a 1 pt stroke
  of `Color.primary.opacity(0.08)`. `fillsHeight` only for equal-height grids.
- **Section header** — `SectionLabel` (uppercase caption, optional SF Symbol),
  used above card content rather than a chrome bar; the app has no top bar.
- **Metric** — `MetricValue` for the one number a card exists to show; unit and
  caption text sit at `.secondary`.
- **Action hierarchy** — `PrimaryActionButtonStyle` (`DesignSystem.swift:340-362`):
  `.headline`, white on `SendmeterStyle.primary`, full-width `minHeight: 48`,
  continuous radius 14, pressed = 0.75 opacity + `scaleEffect(0.98)` +
  `easeOut(0.12)`, plus the structural haptic cue. Secondary/quiet actions use
  the system styles through `hapticButtonStyle(_:)`
  (`Sources/App/StructuralHaptics.swift:145-230`) — bordered, plain or
  glass variants per surface; no second primary recipe exists.
- **Status** — `StatusPill` (`DesignSystem.swift:364-382`): `.caption.weight(.semibold)`
  in the semantic color, 12 % fill, 28 % stroke, capsule. Pills are status
  language, never decoration.
- **Transient messages** — `AppToast` (`DesignSystem.swift:488-555`): capsule,
  `.thickMaterial`, `subheadline.weight(.semibold)`, optional single action,
  auto-dismiss through `ToastLifecycle`. Failure uses `ErrorBanner` instead
  (see the state matrix).

## Spacing, radius, tap targets

| Value | Meaning | Source |
|---|---|---|
| 16 pt | card content padding; the one shared spacing constant | `DesignSystem.swift:7` (`SendmeterStyle.spacing`) |
| 18 pt | shared corner radius for cards **and** sheets | `DesignSystem.swift:6` → `Sources/Core/SheetPresentation.swift:50-52` (`SheetPresentationPolicy.cornerRadius`) |
| 14 pt | primary action button radius | `DesignSystem.swift:353` |
| 12 pt | inline banner radius (error, upload) | `DesignSystem.swift:483`, `Features/History/HistoryView.swift:573` |
| 48 pt | primary action minimum height | `DesignSystem.swift:350` |
| 44 pt | minimum tap target (banner dismiss, watch controls) | `DesignSystem.swift:396`, `WatchDesign.swift:35` |

Local rhythm inside cards (4/8/12 pt stacks) is set per feature and is not a
second scale; prefer the existing `SendmeterStyle.spacing` for new card padding.

## Sheets, full-screen execution, motion, haptics

- **Sheets** — `sendmeterSheetPresentation(dragToDismiss:)` /
  `…(id:dragToDismiss:)` (`Sources/App/SheetPresentation.swift:60-78`) applies
  the shared corner radius, the drag indicator, and the presentation haptic
  lifecycle (`SheetPresentationLifecycle`, `Sources/Core/SheetPresentation.swift:20-46`).
  Item-backed sheets pass their identity so a replacement is one close + one
  open, and classified-close surfaces pass `dragToDismiss: false` while keeping
  their own `.interactiveDismissDisabled` policy.
- **Full-screen execution surfaces (intentional exception)** — active execution
  uses `fullScreenCover`, never a sheet: manual workout and routine runner
  (`Sources/Features/Workout/WorkoutView.swift:104-110`), the guided force
  protocol and the movement/side picker
  (`Sources/Features/Force/ForceView.swift:2000-2026`). These keep fullscreen
  and interactive-dismiss behavior — do not convert them to sheets.
- **Motion** — short and functional: 0.12 s pressed feedback
  (`DesignSystem.swift:356`), 0.2 s banner/toast transitions
  (`SendmeterNativeApp.swift:175-176`). The splash keeps the #841 dyno
  timeline, which is transform-only and collapses to the rest pose under Reduce
  Motion (`SendmeterNativeApp.swift:666-719`).
- **Watch motion** — `WatchDesignTokens.motionDuration` 0.35 s, and **0 s**
  under Reduce Motion (`WatchDesign.swift:39-40`) — removed, not merely slowed.
- **Haptics** — all interactive controls route through `hapticButtonStyle(_:)`
  (`StructuralHaptics.swift:145-230`) so the cue system stays deduped; sheet
  present/dismiss cues come from the shared sheet modifier
  (`Sources/App/Haptics.swift:89-104`). Haptics accompany state changes, never
  replace visible feedback.

## Charts

- **Axis labels (#928/#929)** — one rule, `ChartAxisLabelRule`
  (`native/SendmeterNative/Sources/Core/ChartAxisLabelRule.swift:33-216`):
  label size is `.caption2` (base 11 pt at the default text size), the Canvas
  seeds `@ScaledMetric(relativeTo: .caption2)` with that base and draws with the
  resolved value, and **collision is resolved by thinning labelled ticks**
  (`minimumGap` 6 pt), never by shrinking the text. `insets(…)` grows the plot's
  edges so a larger label stays inside the card; `columnLabelPlan(…)` does the
  same for equal-width column charts (the Training Load weekly bars, #929),
  constrained to the label's own column.
- **Force trace** — `ForceTraceChart` (`ForceView.swift:3011-3100+`): grid in
  `ChartToken.forceTraceGridColor`, plot in `ChartToken.force`, target band in
  `ChartToken.optimal` with the dark-mode opacity floor. The y-domain holds the
  stage band across rep boundaries (#900, `ForceChartYDomainTracker`).
- **Chart color pairs** — `ChartToken` light/dark pairs, `zoneQuality(_:)`
  mapping and `acwrStatusColor(_:_:)` (`ChartTheme.swift:92-170`) are the
  single status mapping shared by the Load card and the projection card.
- Charts expose accessibility descriptors (e.g.
  `accessibilityForceCurveChartDescriptor`, `Sources/Features/Force/NativeForceCurveCard.swift:75`)
  — a chart without one is unfinished work.

## Navigation and chrome

- **Phone**: five tabs, in order — Dashboard, Force, Workout, History, Settings
  (`MainTabView`, `SendmeterNativeApp.swift:605-658`), tinted
  `SendmeterStyle.primary`. The Force and Workout tabs render the approved
  mascot glyphs as templates; the other three keep SF Symbols.
- **Chrome overlays, it does not flex** — app-level status sits in overlays over
  the content: the error banner at the top (`SendmeterNativeApp.swift:135-153`)
  and the toast at the bottom (`:154-174`). On watch, the page strip floats OVER
  the pager so content can use the full screen (watch app `HomeView.swift:337-366`).
  Nothing reintroduces a reserved, in-flow bar.
- The watch Home screen owns its own pager + icon affordances
  (`HomeView.swift:325-366`); watch navigation and always-on rendering are
  watch-owned (`WatchDesign.swift:32-160`).

## Approved artwork geometry (frozen)

Approved masters and their delivered geometry. Do not re-cut, re-scale or
re-tint without owner approval; the asset hashes are the provenance anchor.

| Asset | Delivered geometry | Evidence |
|---|---|---|
| R11 Force hero (`native/SendmeterNative/Resources/Assets.xcassets/ForceMascotLarge.imageset/r11-force-control-160.svg`, SHA-256 `6802e9439ff2fbcd70f60e7f04baf2196c33cf17de6ad309716966221ede6380`) | Force device empty state, 122×118 pt (82×82 compact), template tinted `SendmeterStyle.primary`, decorative (`accessibilityHidden`) | `DesignSystem.swift:226-241`, `docs/design/evidence/issue-894/README.md` |
| R11 Force tab glyph (`native/SendmeterNative/Resources/Assets.xcassets/ForceMascotTab.imageset`) | the SAME master delivered as pinned 1x/2x/3x rasters at a **28 pt optical size**; R11 geometry itself is frozen — the earlier 24 pt attempt did not read on device (#875 r2) | `SendmeterNativeApp.swift:614-637`, `docs/design/evidence/issue-875/README.md`, `Tests/SendmeterCoreTests/TabMascotWiringTests.swift` |
| R16 Workout mascot (`native/SendmeterNative/Resources/Assets.xcassets/WorkoutMascotLarge.imageset/workout-r16-optical-160.svg`, tab master `workout-r16-exact-24.svg`) | Workout tab glyph + Manual workout card hero, same template/tint rules | `docs/design/evidence/issue-875/README.md` |
| Splash composite (`native/SendmeterNative/Resources/Assets.xcassets/SplashCaveBackground.imageset`, `native/SendmeterNative/Resources/Assets.xcassets/SplashKangaroo.imageset`) | cave `scaledToFill` cropped at 57 % (64 % ≥720 pt), kangaroo stage `clamp(290, 80vw, 410)`, transform origin `(0.5, 0.52)` | `SendmeterNativeApp.swift:660-760` |

The Force tab's larger optical rendering and the watch Force nav-card hue are
**recorded deviations**, not new rules — see Decisions.

## State matrix

Truthful states, their copy and their action. "Owner" names the slice that
owns the semantics; where a row says *descriptive*, the behavior below is what
the tree does today.

| State | What the user sees | Copy / action contract | Owner |
|---|---|---|---|
| **Loading** | inline `ProgressView`, never a blank card | "Loading recent sessions…" (`DashboardView.swift:367-369`), "Loading training history…" (`AcwrProjectionCard.swift:96-98`), "Loading force-duration curve…" (`NativeForceCurveCard.swift:99-102`), "Connecting to Progressor…" (`NativeForceCurveCard.swift:84-86`); the app splash shows "Starting Sendmeter" (`SendmeterNativeApp.swift:728-730`) | descriptive; loading is gated on `isLoadingData || isRefreshing` and shown only while nothing is authoritative yet |
| **Authoritative empty** (loaded, nothing to show) | `ProductEmptyState` with art + one action | "Your next send starts here" / "Start a workout"; "Your next workout shapes the forecast" / "Start a workout"; "Shape your force curve" / record a pull; Force device: "Your first pull starts here" / "Open Bluetooth Settings" (`DashboardView.swift:379-386`, `AcwrProjectionCard.swift:108-116`, `NativeForceCurveCard.swift:87-93`, `ForceView.swift:2651-2660`) | descriptive; empty is only stated once the load has completed (`hasLoadedSessions`) |
| **Cached / stale** | a dated "Last synced" line stays visible instead of claiming freshness | phone: "Last synced \<date\>" (`DashboardView.swift:211-214`) and Settings "Last synced" (`SettingsView.swift:281-291`); a failed refresh keeps the previous reading and says so ("Apple Health refresh failed; previous reading kept", `DashboardView.swift:220-224`); watch: chip/queue states `cached` → "Cached" and `stale` → "Needs attention" (`WatchDesign.swift:163-198`, `StatusView.swift:36-62`), banner "Last synced Nm ago" / "Nothing has synced yet" with the retry claim only when a retry is actually armed (`HomeView.swift:642-652`, `SyncFreshness.swift:17-46`) | descriptive |
| **Pending** (work accepted locally, not yet on the server) | History banner + row badges + Settings counters | "Uploads waiting" with "N queued on this iPhone · N on your watch" and a single **Retry** that also re-attempts quarantined items (`HistoryView.swift:520-623`); rows read "Pending" in `caution`, and a restored rejected placeholder reads "**Rejected**", never "Pending"/"Syncing" (`HistoryView.swift:757-766`); Settings: "Pending uploads" pill — "Synced" / "N unsynced" / "N queued" (`SettingsView.swift:506-517`, `547-557`) | **U01 (#920)** owns pending status + Retry semantics. Today's copy above is the last shipped (#630-6/#675) behavior; U01 may change only what it routes |
| **Synced** | affirmative status, no banner | Settings pill "Synced" when `queuedWriteCount + pendingCacheWriteCount == 0` (`SettingsView.swift:506-509`); watch chip "Synced" only for a complete refresh — a partial refresh with a cached snapshot is `cached`, never `synced` (`WatchDesign.swift:214-231`, chip copy in `StatusView.swift:36-62`); watch "Saved" state (`WatchDesign.swift:181`) | descriptive |
| **Failure** | top overlay `ErrorBanner`, or a state-local message | `ErrorBanner`: alert-tinted (12 %) card, message wraps fully at every text size, **Dismiss** is a 44 pt real target labeled "Dismiss error", a new message is announced once and rerenders are silent (`DesignSystem.swift:384-486`, `SendmeterNativeApp.swift:135-153`); watch "Error"/"Caution" states (`WatchDesign.swift:181-182`); a **refused End inside an active manual workout** must be explained in that screen — today's gap | **U03 (#927)** owns the banner contract (shipped); **U02 (#926)** owns in-workout refusal feedback (routed, PR open at this base) |

Rules that hold across rows:

- Unknown is not zero: an unread watch quarantine renders as unknown, not as
  "nothing quarantined" (`HistoryView.swift:524-537`, #675 F8).
- A rejected item is never described as pending or retrying
  (`HistoryView.swift:759-766`).
- A stale value never borrows the "Synced" state
  (`WatchDesign.swift:214-231`, `SyncFreshness.swift:17-46`).

## Descriptive vs future acceptance

| Rule | Class | Enforced by |
|---|---|---|
| Semantic hues, bands, dark pairs | descriptive | `SendmeterStyle`, `ChartToken`, `ReadinessWidgetSemanticToken`, `WatchDesignTokens` + their tests |
| Dynamic Type treatment of metrics, labels, axes | descriptive | `HeroMetricModifier`, `CountdownMetricModifier`, `ChartAxisLabelRule` + `ChartAxisLabelRuleTests` |
| Cards/actions/spacing/radius/tap targets | descriptive | `DesignSystem.swift`, `SheetPresentationPolicy` |
| Sheet lifecycle vs full-screen execution surfaces | descriptive | `SheetPresentationWiringTests`, `WorkoutView`/`ForceView` presentation code |
| Mascot geometry + tints | frozen / descriptive | `TabMascotWiringTests`, `EmptyStateWiringTests`, `ForceEmptyStateArtworkWiringTests` |
| Pending/Retry semantics reflect real recoverable mutations | **future acceptance** | U01 (#920), depends on W01–W04 (shipped) |
| Refused End feedback inside the active workout | **future acceptance** | U02 (#926), routed |
| Error banner dismiss/announce contract | descriptive (shipped #927) | `ErrorBannerAccessibilityTests`, `ErrorBannerDismissUITests` |
| Scalable chart axes | descriptive (shipped #928/#929) | `ChartAxisLabelRuleTests`, `WorkoutChartAxisWiringTests` |

## Decisions and open items

Unapproved or owner-recorded stylistic choices, listed rather than silently
adopted:

1. **Pending/Retry semantics (U01, #920)** — open. This document records the
   shipped copy; it does not pre-approve a new pending/retry design.
2. **In-workout refusal feedback (U02, #926)** — routed; the fix must land in
   the active manual-workout screen, not as a new global banner.
3. **Watch Force-module hue** — the Home nav card keeps the pink `force` accent
   as an accepted, revertible deviation from #538 AC-2
   (`WatchDesign.swift:70-82`); generic Force controls use
   primary/success/warning/danger.
4. **Dark chart pairs derived from the retired web hexes** — retained as the
   phone's dark adaptation (`ChartTheme.swift:193-212`). A native retune is a
   future decision, not a free edit.
5. **Force tab optical rendering at 28 pt** — the delivered size for the frozen
   R11 master (#875 r2); re-cutting the artwork is out of bounds.
6. **CI wiring of the doc checks** — `scripts/check-docs-stale-commands.sh`
   (#931) is not yet wired into CI; #944 owns that. This document's own check is
   run manually/by the lane and is **not** wired from `.github/**` here.

## Preserved exceptions (do not "fix")

- Immersive execution surfaces stay full-screen (manual workout, routine
  runner, guided force, movement picker) — `Sources/App/SheetPresentation.swift:5-10`.
- Navigation stays five tabs in the shipped order; the mascot tab glyphs stay
  on Force and Workout.
- Frozen mascot/Force geometry and the splash composite (above).
- Watch always-on dimming is 42 % of the accent for decorative pixels, with
  text/symbols resolved back to the 4.5:1 contrast floor
  (`WatchDesign.swift:42-50`, `WatchDesign.swift:88-125`).
- Watch Force nav-card hue deviation (decision 3).

## Historical: retired web/Capacitor design spec (pre-#857)

<!-- design-contract:historical:begin -->

Everything between these markers is **historical record only**. It described
the React/Vite/Capacitor web app removed in #857 and must not be followed:
CSS custom properties (`--t-*`, `--bg`, `data-theme`), the CSS class recipes
(`.btn-primary`, `.bottom-nav`, `.account-fab`, `.modal-sheet`), the
`src/index.css` / `public/fonts` paths, the Inter / DM Mono / Syne font
pairing, the ripple hook, and the PWA/`theme-color` identity are all retired.
The removal inventory that decided REMOVE vs KEEP is
`docs/architecture/857-removal-inventory.md`.

What survived the cut, in native form, is recorded above: the semantic hues,
the metric-first typography, the card hierarchy and the health scale now live
in Swift. The one web-era behavior the splash deliberately keeps is the #841
dyno timeline (transform-only, reduced-motion aware) — see Motion.

- Theme tokens `:root` / `:root[data-theme="dark"]` / `prefers-color-scheme`,
  `--bg`, `--canvas`, `--card-border`, `--ink*`, `--primary*`, `--success`
  (`#1674BE`), `--warning`, `--danger` (`#B95122`), `--orange`, `--t-*` type
  scale (9–20 px), `--radius-card`, floating glass chrome via
  `backdrop-filter: blur(24px)`, `.bottom-nav` auto-hide/collapse, `useRipple`
  iridescent taps, `grid-2-desktop` ≥720 px layout.
- Fonts: self-hosted Inter (`public/fonts/OFL.txt`), `font-variant-numeric:
  tabular-nums`, later DM Mono/Syne pairing — all replaced by system SF.
- Commands and paths: `npm run dev`, `npx cap sync`, `vite build`,
  `capacitor.config.ts`, `ios/App/App/public`, scheme `App` — retired with the
  Capacitor host (see `scripts/check-docs-stale-commands.sh` for the enforced
  name list).
- Contradictions this file previously carried and the native resolution:
  "target zone = translucent green band" → in-zone force is `optimal` blue
  (`ForceView.swift:2662-2666`); "`--success` is electric blue" → the phone's
  completion/green semantics are limited to the watch `success` token
  (`WatchDesign.swift:67`).

<!-- design-contract:historical:end -->

## How this document is checked

`scripts/check-design-contract.sh` (run from the repo root) validates this
file against the tree:

1. every cited repo path exists, and a `file:line[-line]` citation is inside
   the file's line count;
2. every symbol in the [Symbol index](#symbol-index) below still appears in its
   cited source file;
3. retired web/Capacitor tokens appear **only** between the
   `design-contract:historical` markers.

Exit `0` clean, `1` on any violation (printed as `FAIL: …`), `2` on a setup
problem. It is deliberately lightweight — it proves references resolve, not
that prose is true; the code citations remain the reviewer's check.

### Symbol index

| Symbol | Source |
|---|---|
| `SendmeterStyle` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `HeroMetricModifier` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `CountdownMetricModifier` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `SurfaceCard` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `ProductEmptyState` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `SectionLabel` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `MetricValue` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `PrimaryActionButtonStyle` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `StatusPill` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `ErrorBannerAccessibility` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `ErrorBanner` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `AppToast` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `SheetPresentationPolicy` | `native/SendmeterNative/Sources/Core/SheetPresentation.swift` |
| `SheetPresentationLifecycle` | `native/SendmeterNative/Sources/Core/SheetPresentation.swift` |
| `sendmeterSheetPresentation` | `native/SendmeterNative/Sources/App/SheetPresentation.swift` |
| `ChartToken` | `native/SendmeterNative/Sources/App/ChartTheme.swift` |
| `ChartActivityHue` | `native/SendmeterNative/Sources/App/ChartTheme.swift` |
| `ChartAxisLabelRule` | `native/SendmeterNative/Sources/Core/ChartAxisLabelRule.swift` |
| `SendmeterSemanticHue` | `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/WatchDesign.swift` |
| `WatchDesignTokens` | `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/WatchDesign.swift` |
| `WatchVisualState` | `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/WatchDesign.swift` |
| `WatchStatusRefreshState` | `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/WatchDesign.swift` |
| `SyncFreshnessPolicy` | `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/SyncFreshness.swift` |
| `ReadinessWidgetSemanticToken` | `native-plugins/sendlog-health-core/Sources/SendLogHealthCore/ReadinessWidgetContract.swift` |
| `ReadinessWidgetReadinessBand` | `native-plugins/sendlog-health-core/Sources/SendLogHealthCore/ReadinessWidgetContract.swift` |
| `AppThemeController` | `native/SendmeterNative/Sources/App/AppThemeController.swift` |
| `MainTabView` | `native/SendmeterNative/Sources/App/SendmeterNativeApp.swift` |
| `ForceTraceChart` | `native/SendmeterNative/Sources/Features/Force/ForceView.swift` |
| `NativeForceCurvePlot` | `native/SendmeterNative/Sources/Features/Force/NativeForceCurveCard.swift` |
| `Haptics` | `native/SendmeterNative/Sources/App/Haptics.swift` |
| `hapticButtonStyle` | `native/SendmeterNative/Sources/App/StructuralHaptics.swift` |
| `ProductEmptyStateArtwork` | `native/SendmeterNative/Sources/App/DesignSystem.swift` |
| `ReadinessWidget` | `native/SendmeterNative/Sources/Widgets/ReadinessWidget.swift` |
| `TabMascotWiringTests` | `native/SendmeterNative/Tests/SendmeterCoreTests/TabMascotWiringTests.swift` |
| `EmptyStateWiringTests` | `native/SendmeterNative/Tests/SendmeterCoreTests/EmptyStateWiringTests.swift` |
| `ForceEmptyStateArtworkWiringTests` | `native/SendmeterNative/Tests/SendmeterCoreTests/ForceEmptyStateArtworkWiringTests.swift` |
| `ChartAxisLabelRuleTests` | `native/SendmeterNative/Tests/SendmeterCoreTests/ChartAxisLabelRuleTests.swift` |
| `ErrorBannerAccessibilityTests` | `native/SendmeterNative/Tests/SendmeterNativeTests/ErrorBannerAccessibilityTests.swift` |
| `ErrorBannerDismissUITests` | `native/SendmeterNative/Tests/SendmeterNativeUITests/ErrorBannerDismissUITests.swift` |
| `SheetPresentationWiringTests` | `native/SendmeterNative/Tests/SendmeterNativeTests/SheetPresentationWiringTests.swift` |
| `WorkoutChartAxisWiringTests` | `native/SendmeterNative/Tests/SendmeterCoreTests/WorkoutChartAxisWiringTests.swift` |

Not in the index on purpose: file-only citations (features, assets, workflows)
are covered by check 1, and prose names like "Force tab" are not symbols.
