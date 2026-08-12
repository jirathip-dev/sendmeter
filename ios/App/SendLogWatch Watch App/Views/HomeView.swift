import SendLogWatchCore
import SwiftUI

/// The watch home: two swipeable pages (#278). Page 1 is status — what shape
/// am I in — and page 2 is the things you can start. Swiping starts nothing;
/// page 2 has the same taps it always had.
///
/// Horizontal `.page` paging, not `.verticalPage`: both pages scroll vertically
/// when text wraps, and that scrolling is driven by the Digital Crown — vertical
/// paging would fight the scroll on every page. Sideways also matches the mental
/// model better, since neither page is "below" the other.
///
/// This stays the root of RootView's NavigationStack, so the two
/// `NavigationLink(value:)`s below and the complication deep links push onto
/// the same path. The `.navigationDestination` lives up in RootView, outside
/// the TabView — a destination declared inside a paged TabView is only
/// registered while its page is realized, which is exactly how a deep link
/// arriving on the wrong page silently does nothing.
/// #486 review F6: `GaugeSessionLossNotice` and `RecordingLossNotice` are
/// both destructive one-shot `UserDefaults` flags, and — far from an
/// exotic edge case — the SAME event can set both: a BLE drop mid-hold can
/// both lose the in-flight rep (`RecordingLossNotice`) AND, since
/// `logSessionNow()` always runs right after, fail to log the gauge session
/// that was grouping it (`GaugeSessionLossNotice`). Two independently
/// chained `.alert` modifiers on one view race to present; whichever loses
/// has ALREADY had its `consume()` called (destructive, before the race even
/// starts), so that notice is gone for good — precisely the #264 "reported,
/// never swallowed" failure the notices exist to prevent. `LossNotice` below
/// queues whatever `onAppear` consumed and a single `.alert` presents them
/// one at a time, advancing on dismiss.
enum LossNotice: Equatable {
    case gaugeSession
    case recording
    /// #491 review R1: NOT a loss, despite the enum's name (kept for the
    /// queue-of-one-alerts mechanism it rides) — the new rep was saved, and
    /// an older recording the server had permanently rejected gave up its
    /// stored force curve to make room. Must never reuse the loss copy:
    /// telling a user a rep "is gone" when it is safely on disk is #264's
    /// dishonesty mirrored.
    case quarantineTrim

    /// #495 R4: `onAppear` used to ASSIGN the freshly consumed notices over
    /// `lossQueue` — if an earlier notice was still waiting (its alert was
    /// dismissed by navigation before anyone tapped OK), the assignment
    /// silently dropped it: the durable flag had already been consumed, so
    /// the loss was never presented anywhere. Same shape as the round-1
    /// finding on #486 (a consumed-but-never-presented notice), one step
    /// later in the pipeline. Merge instead: whatever is still waiting stays
    /// at the front, newly consumed kinds append behind it. A kind already
    /// waiting is not duplicated — the backing flags are one-shot booleans,
    /// so any number of losses of one kind collapse to a single notice
    /// anyway, and presenting it twice would claim two events we cannot
    /// actually distinguish.
    static func merged(existing: [LossNotice], consumed: [LossNotice]) -> [LossNotice] {
        var merged = existing
        for notice in consumed where !merged.contains(notice) {
            merged.append(notice)
        }
        return merged
    }

    var title: String {
        switch self {
        case .gaugeSession: return "Force session not saved"
        case .recording: return "A force rep was lost"
        case .quarantineTrim: return "Made room for your new rep"
        }
    }

    var message: String {
        switch self {
        case .gaugeSession:
            return "Your force recordings may appear ungrouped in History. Create a session for them on your phone."
        case .recording:
            return "A recording couldn't be saved to your watch or uploaded. It's gone — the rest of your session is unaffected."
        case .quarantineTrim:
            return "Your new rep was saved. Storage was full, so an older recording the server kept rejecting gave up its stored force curve — its summary numbers remain."
        }
    }
}

struct HomeView: View {
    @Binding var selection: WatchHomePage
    // #476 review finding F4: `sendmeter://status` sends the user to page 1
    // (`StatusView`), but the "workout running" hint used to live only in
    // `ActionsView` (page 2) — a status complication tap mid-workout landed
    // on a page that said nothing about it, reachable only by a blind swipe.
    // A banner ABOVE the pager, outside the `TabView`, is visible on
    // whichever page is selected.
    @Environment(WorkoutManager.self) private var workout

    // #486 review F6 supersedes the old single `showGaugeSessionLoss` flag:
    // two chained `.alert`s each with a destructive `consume()` could swallow
    // a notice when only one presented. One queue, one alert.
    @State private var lossQueue: [LossNotice] = []
    @State private var showLossAlert = false

    /// SL-586 raises the page-toggle icons from their own 44pt row into the
    /// system top strip (the safe-area band where watchOS draws the time,
    /// top-RIGHT — the icons take the top-LEFT region beside it), freeing
    /// that whole row for content. The strip height is measured from the
    /// live safe-area inset (GeometryReader below), never hardcoded: it
    /// differs per case size (measured 32.5pt on 40mm, 44.5pt on 46mm,
    /// 47.5pt on 49mm — the `systemClockCenterY` calibration table).
    ///
    /// Half of `WatchIconButtonVisuals.visibleDiameter` (30pt) — KEEP IN
    /// SYNC, same contract as `selectorButtonBackdrop`'s 30pt disc below.
    /// The disc centers sit at `systemClockCenterY(strip:)` (never above
    /// the calibration's lower anchor), so the visible ink stays ≥0.2pt
    /// inside the physical top edge on the smallest case size.
    private static let discRadius: CGFloat = 15
    /// Defensive floor for the measured strip; no real watch reports less,
    /// but a zero inset must not put the icons on top of at-rest content.
    private static let minimumStripHeight: CGFloat = 24
    /// Breath between the chrome's bottom edge (the strip, or the discs'
    /// lower edge when a device's clock sits low in the strip) and at-rest
    /// page content, so the discs never touch the cards until the user
    /// scrolls.
    private static let contentBreath: CGFloat = 6

    /// The system clock's optical center — the vertical target for the icon
    /// discs — as a function of the runtime top safe-area inset (the strip).
    /// Calibrated from 2x simulator captures on watchOS 26.5 (2026-08-12,
    /// same pixel method as the #596 report):
    ///
    ///   case size (pt)      strip (safe-area top)   clock center
    ///   40mm SE 3  162×197  32.5                     15.2
    ///   46mm S11   208×248  44.5                     25.5
    ///   49mm Ultra 211×257  47.5                     28.0
    ///
    /// The three points are collinear — 46mm interpolates to 25.4 vs the
    /// measured 25.5 — so a linear interpolation between the 40mm and 49mm
    /// anchors reproduces every measured size within a pixel, and the input
    /// (the live strip) already varies per device. #597 instead applied a
    /// device-invariant 0.55×strip to a fictional strip: the real one is
    /// TALLER than the clock band, and the clock's center sits at 0.47
    /// (40mm) / 0.59 (49mm) of it — no constant fraction exists, which is
    /// why the discs rode the top bezel on Ultra while sitting ~1pt off the
    /// physical edge on 40mm. Values clamp to the anchor range: a case size
    /// outside it must not push the discs above the measured 40mm position
    /// (which would cross the physical top edge) or below the 49mm one.
    /// Re-measure this table if a watchOS update moves the system clock.
    private static func systemClockCenterY(strip: CGFloat) -> CGFloat {
        let strip40mm: CGFloat = 32.5
        let strip49mm: CGFloat = 47.5
        let center40mm: CGFloat = 15.2
        let center49mm: CGFloat = 28.0
        let clamped = min(max(strip, strip40mm), strip49mm)
        let fraction = (clamped - strip40mm) / (strip49mm - strip40mm)
        return center40mm + (center49mm - center40mm) * fraction
    }

    /// Per-button legibility backdrop (#588 review F3): a canvas-colored
    /// disc matching the primitive's 30pt visible circle. Over the dark
    /// at-rest canvas it is invisible; over a bright card sliding under the
    /// transparent bar it keeps the dim unselected glyph readable — the
    /// user's direction is per-button backdrops, never a bar-wide band.
    /// `canvas` is the same in full and reduced luminance, so Always-On
    /// needs no variant.
    private var selectorButtonBackdrop: some View {
        Circle()
            .fill(WatchPalette.canvas.opacity(0.9))
            .frame(width: 30, height: 30)
    }

    private var activeLossNotice: LossNotice? { lossQueue.first }

    /// The clock-level icon row (SL-586). Leading padding + tight spacing
    /// keep both visible discs well clear of the system time on a 162pt-wide
    /// 40mm face: discs span x ≈ 15…77 while the rendered clock starts
    /// ≈ 120 — the screenshot suite asserts that margin explicitly. The
    /// `.frame(height: strip)` centers the 44pt buttons on the strip's
    /// midline; the offset then pins the disc centers at
    /// `systemClockCenterY(strip:)` — the system clock's measured optical
    /// center on this case size — never letting visible ink cross the
    /// physical top edge (the calibration clamps to the measured 40mm
    /// anchor, where the disc top sits 0.2pt inside the edge).
    private func selectorRow(strip: CGFloat) -> some View {
        let discCenterY = Self.systemClockCenterY(strip: strip)
        return HStack(spacing: 2) {
            WatchIconButton(
                systemImage: WatchIconSymbol.status,
                accessibilityLabel: "Show Status",
                accessibilityHint: "Displays today's readiness and training load",
                accessibilityIdentifier: "home-nav-status",
                isSelected: selection == .status,
                action: { selection = .status }
            )
            .background { selectorButtonBackdrop }
            WatchIconButton(
                systemImage: WatchIconSymbol.actions,
                accessibilityLabel: "Show Actions",
                accessibilityHint: "Displays Force Gauge and Climb Workout",
                accessibilityIdentifier: "home-nav-actions",
                isSelected: selection == .actions,
                tint: WatchDesignTokens.secondary,
                action: { selection = .actions }
            )
            .background { selectorButtonBackdrop }
        }
        .padding(.leading, 6)
        .frame(height: strip, alignment: .center)
        .offset(y: discCenterY - strip / 2)
    }

    var body: some View {
        // The root content ignores the TOP safe area as well as the bottom
        // one now (SL-586), so the pager runs under the system strip and the
        // icons can sit inside it. The GeometryReader is what still knows
        // where the strip ends: applied to the CONTENT instead of to the
        // reader (see below), `ignoresSafeArea` leaves the reader reporting
        // the true safe-area top — the system strip — which every piece of
        // the new geometry (icon row, fade height, at-rest content inset)
        // derives from instead of a hardcoded bar height.
        GeometryReader { geo in
            let strip = max(geo.safeAreaInsets.top, Self.minimumStripHeight)
            // The real chrome is the clock-level discs: their lower edge is
            // where the strip's paintable region actually ends for content.
            // The at-rest inset and the fade mask follow the strip (which
            // the clock band never exceeds — it sits in the strip's upper
            // part), with the disc bottom as a belt-and-braces floor so a
            // device whose clock sits low in the strip still can't overlap
            // its own at-rest cards.
            let discCenterY = Self.systemClockCenterY(strip: strip)
            let discBottom = discCenterY + Self.discRadius
            let contentTop = max(strip, discBottom) + Self.contentBreath
            VStack(spacing: 2) {
                if workout.isRunning {
                    WatchStateBanner(
                        state: .warning,
                        title: "Workout in progress",
                        message: "Open Climb Workout to end it safely."
                    )
                    .padding(.horizontal, 4)
                    // The stack starts at the physical top now — keep the
                    // banner's card out of the system strip (and from under
                    // the clock-level icons).
                    .padding(.top, strip)
                }
                TabView(selection: $selection) {
                    // Applied per page, NOT via `safeAreaInset` on the TabView:
                    // page-style TabView children are their own hosting roots on
                    // watchOS and never received the TabView-level inset — at
                    // rest, the readiness/Force cards rendered straight under
                    // the selector circles (the fixture matrix caught it). The
                    // same hosting-root independence also keeps each page's
                    // OWN container safe area (the true top strip, ~32.5pt on
                    // 40mm) even though the outer stack ignores it — so each
                    // page must ignore it itself. The safe-area padding sits
                    // FIRST, inside the ignore: reversed (ignore then pad),
                    // `ignoresSafeArea` eats the padding and the at-rest
                    // cards land back under the discs (measured 0.5pt, caught
                    // by the suite's card-below-discs assertion). The padding
                    // then gives each page's at-rest content a clear top
                    // margin below the discs (the real chrome, per the
                    // SL-586 follow-up) while its scrolled content still
                    // passes visibly underneath. Deliberately constant even
                    // when the workout banner pushes the pager below the
                    // strip: a pad shorter than the fade mask would leave
                    // at-rest cards half-dissolved.
                    StatusView()
                        .safeAreaPadding(.top, contentTop)
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                        .tag(WatchHomePage.status)
                    ActionsView()
                        .safeAreaPadding(.top, contentTop)
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                        .tag(WatchHomePage.actions)
                }
                // The explicit selector (the clock-level icons below) is the
                // only pagination affordance; the native dots duplicate it
                // and consume scarce 40mm height.
                .tabViewStyle(.page(indexDisplayMode: .never))
                // #578's guarantee, softened (SL-580 follow-up): the pages must
                // never paint OVER the selector controls or escape the pager, but
                // the old hard `.clipped()` guillotined scrolled cards at a
                // razor-straight line just under the icons — a bright card cut
                // mid-body made the whole selector row read as a solid black
                // band. This alpha mask keeps the same ownership boundary (all
                // painting outside the pager's bounds is still fully masked
                // away) while the top of the scroll region fades over the
                // strip's height, so content visibly slides UNDER the icons
                // and the system clock and dissolves instead of being
                // chopped. Pure geometry — no color is introduced, so
                // Always-On dimming and Reduce Motion are untouched.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        // Exactly the chrome's height (#588 review F4,
                        // rebased onto the strip): the fade reaches full
                        // opacity at the strip's bottom edge, so the
                        // least-faded content band begins where the chrome
                        // ends instead of leaving a fully-unfaded strip
                        // beside the icons/clock.
                        .frame(height: strip)
                        Rectangle().fill(Color.black)
                    }
                }
                // Identify the pager for clipping assertions. The icon row
                // lives on the OUTER stack now (it must hold clock level even
                // when the workout banner pushes the pager down), which also
                // retires the old ordering footgun — the identifier no longer
                // shares a node with the buttons at all, so it cannot swallow
                // their identifiers (the documented container-identifier
                // trap that once removed the nav buttons from the tree).
                .accessibilityIdentifier("home-pager-viewport")
            }
            // #539/#541: two compact `WatchIconButton`s as the explicit
            // two-way page affordance (VoiceOver gets named "Show Status"/
            // "Show Actions" controls instead of a blind swipe). SL-586
            // raises them to the system-time level: watchOS reserves the
            // strip's top-RIGHT for the clock, so the icons take the LEFT
            // region beside it and the old dedicated bar row goes back to
            // content. Still floating chrome OVER the pager (DESIGN.md:
            // auto-hiding chrome must overlay, not flex) with the strip area
            // itself transparent; per-button canvas-colored backdrops keep
            // the buttons legible over passing content — the unselected
            // primitive's own fill is a near-transparent 8% white, which is
            // not legibility over a bright card (#588 review F3) — while the
            // strip stays backdrop-free per the user's direction. The
            // overlay renders above the pages, so the controls can never be
            // covered or lose their hit targets — the actual #578 regression
            // this layout must not reintroduce.
            //
            // NOT a toolbar `.topBarLeading` item, on purpose: #580 already
            // established that the shared 44pt primitive inside a watchOS
            // toolbar renders as an oversized square whose frame "is
            // watchOS's to clip" (WorkoutLiveView's app-owned top row is the
            // surviving fix). This overlay is the topBarLeading *equivalent*
            // that keeps the fixture/production control path intact. The
            // 44pt hit frames cannot fit inside the strip (32.5pt on 40mm),
            // so they follow WorkoutLiveView's shorter-slot doctrine: the
            // invisible overhang crosses only the physical top bezel and the
            // pages' top breath — never another control or visible content.
            .overlay(alignment: .topLeading) {
                selectorRow(strip: strip)
            }
            // The safe-area insets are the rounded-corner / Digital Crown
            // exclusion zones, not additional visual gutters for this
            // full-screen pager. Bottom: keeping the inset on the root stack
            // left the pager's clip edge ~19pt above the captured framebuffer on
            // a 40mm watch, which cut the scored readiness card after its
            // production sync line. Top (SL-586): the strip must be paintable so
            // scrolled content dissolves under the clock and the icons can sit
            // beside it.
            //
            // Applied to the CONTENT (inside the GeometryReader), not to the
            // reader itself: the reader must keep reporting the true top safe
            // area inset — the system strip where watchOS draws the clock —
            // because every piece of the geometry above derives from it. Under
            // the #597 stack (ignoresSafeArea outside the reader) the reader
            // measured 0.0 on both 40mm and 49mm simulators, the 24pt floor
            // supplied the whole strip, and the icons pinned at the 16pt
            // defensive floor — which is why they rode the top bezel on the
            // larger Ultra clock band (SL-586 follow-up). The measured strips
            // are 32.5pt (40mm), 44.5pt (46mm) and 47.5pt (49mm).
            .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        // The home title duplicated the app identity while consuming the
        // exact vertical budget the 40mm status card needs. The system time
        // remains visible; pushed screens still provide their own titles.
        .toolbar(.hidden, for: .navigationBar)
        .watchCanvas()
        .onAppear {
            var consumed: [LossNotice] = []
            if GaugeSessionLossNotice.consume() { consumed.append(.gaugeSession) }
            if RecordingLossNotice.consume() { consumed.append(.recording) }
            // Real losses first; the not-a-loss trim notice (#491 R1) last.
            if QuarantineTrimNotice.consume() { consumed.append(.quarantineTrim) }
            // #495 R4: MERGE onto whatever is still waiting (see
            // `LossNotice.merged`) — assigning here dropped an un-presented
            // notice — and re-present whenever the queue is non-empty, even
            // if nothing new was consumed this time: a navigation-dismissed
            // alert left `showLossAlert` false with its notice still queued,
            // which the old `guard !notices.isEmpty` return left stuck
            // forever.
            lossQueue = LossNotice.merged(existing: lossQueue, consumed: consumed)
            if !lossQueue.isEmpty { showLossAlert = true }
        }
        .alert(activeLossNotice?.title ?? "", isPresented: $showLossAlert) {
            Button("OK", role: .cancel) {
                if !lossQueue.isEmpty { lossQueue.removeFirst() }
                guard !lossQueue.isEmpty else { return }
                // Deferred a tick: SwiftUI is still processing this alert's
                // own dismiss (which also writes `showLossAlert = false`) —
                // flipping it back to true in the same pass is exactly the
                // "two alerts racing" shape this fix exists to avoid, just
                // sequential instead of concurrent. One tick later, the
                // dismiss has fully settled and the SAME `.alert` (now
                // reading the next `activeLossNotice`) presents cleanly.
                DispatchQueue.main.async { showLossAlert = true }
            }
        } message: {
            Text(activeLossNotice?.message ?? "")
        }
    }
}

/// Page 2 — the things you can start from the wrist.
private struct ActionsView: View {
    @Environment(AuthManager.self) private var auth
    @State private var pendingUploads = 0
    /// nil until the `.task` below resolves (review F22) — unknown must not
    /// render as `.current`/healthy, so the row simply doesn't show until
    /// there's an actual reading, rather than defaulting to "fine".
    /// #481 (#472 F23): this is a snapshot taken once by `.task` when the view
    /// appears, not re-evaluated while it stays on screen — a queue that goes
    /// stale (or recovers) mid-appearance won't move this row until the next
    /// appearance, and `staleSyncMessage`'s "retrying automatically" is only
    /// ever true as of that one fetch. Recorded rather than fixed: a live
    /// refresh needs a real trigger (a timer or a queue-state publisher), not
    /// a one-line change.
    @State private var syncFreshness: SyncFreshness?
    /// Whether `OfflineQueue` currently has a backoff retry armed (review
    /// F18) — read alongside `syncFreshness` so the row's copy can say
    /// "retrying automatically" only when that's actually true, rather than
    /// asserting it for every stale reading.
    @State private var retryScheduled = false

    private var visiblePendingUploads: Int { ScreenshotFixtures.actionPendingUploads ?? pendingUploads }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchEyebrow(text: "Start a session")
                    .frame(maxWidth: .infinity, alignment: .leading)

                WatchCard(accent: WatchPalette.force) {
                    NavigationLink(value: WatchDest.force) {
                        HStack(spacing: 10) {
                            Image(systemName: "scalemass")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.force))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Force Gauge")
                                    .font(.system(.footnote, design: .rounded).weight(.bold))
                                Text("Measure a hold with Progressor")
                                    .font(.caption2)
                                    .foregroundStyle(WatchPalette.textSecondary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.75)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(WatchPalette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-action-force")
                    .accessibilityHint("Opens force gauge setup")
                }

                WatchCard(accent: WatchPalette.secondary) {
                    NavigationLink(value: WatchDest.workout) {
                        HStack(spacing: 10) {
                            Image(systemName: "figure.climbing")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.secondary))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Climb Workout")
                                    .font(.system(.footnote, design: .rounded).weight(.bold))
                                Text("Count boulders and track effort")
                                    .font(.caption2)
                                    .foregroundStyle(WatchPalette.textSecondary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.75)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(WatchPalette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-action-workout")
                    .accessibilityHint("Opens climb workout")
                }

                // The "workout running" hint lives in HomeView now, above the
                // pager (#476 review finding F4) — it needs to be visible on
                // whichever page a status/force deep link lands on, not just here.

                if visiblePendingUploads > 0, ScreenshotFixtures.actionState == nil {
                    WatchStateBanner(
                        state: .offline,
                        title: "\(visiblePendingUploads) upload\(visiblePendingUploads == 1 ? "" : "s") waiting",
                        message: "Saved on the watch; they upload when your iPhone is in range."
                    )
                }

                if let actionState = ScreenshotFixtures.actionState {
                    WatchStateBanner(
                        state: actionState,
                        title: actionState == .syncing ? "Syncing uploads" : "Offline saves",
                        message: actionState == .syncing
                            ? "Your latest save is being sent to the iPhone."
                            : "\(visiblePendingUploads) saves stay on the watch until the connection recovers."
                    )
                }

                // The offline window (#265): the relayed access token has expired
                // and only the phone can supply another. Recording still works —
                // everything is persist-first and drains later — so say that
                // rather than dumping the user on a sign-in screen mid-session.
                if auth.needsTokenForDisplay && !ScreenshotFixtures.enabled {
                    WatchStateBanner(
                        state: .offline,
                        title: "Waiting for iPhone",
                        message: "New saves upload once it is in range."
                    )
                } else if case let .stale(lastSuccessfulSyncAt)? = syncFreshness, !ScreenshotFixtures.enabled {
                // #472b: a different signal from the row above — items are
                // waiting AND the queue hasn't landed anything in a while,
                // which `auth.needsToken` alone wouldn't catch (a queue can
                // stall on a real outage or an unrecognized rejection with a
                // perfectly fresh token). Shown only when `needsToken` isn't
                // already saying something (review nit: the two otherwise
                // overlap, and the `needsToken` row already covers "no token
                // yet" — the case where nothing is actually retrying, F18).
                // Same honest-states rule as everywhere else here: never
                // having synced reads as stale, not as quiet/healthy.
                    WatchStateBanner(
                        state: .stale,
                        title: staleSyncMessage(lastSuccessfulSyncAt, retryScheduled: retryScheduled),
                        message: "Pending uploads stay on the watch until the connection recovers."
                    )
                }
            }

            // No Sign Out here, and none anywhere else on the watch (#278).
            // The watch has no session of its own to end — it mirrors the
            // phone's — and the old button called supabase-swift's
            // globally-scoped signOut, which revoked every session on the
            // account, including the phone's. The "Signed in from your iPhone"
            // footer went with it: automatic sign-in is the normal path and
            // doesn't need narrating.
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 4)
        .watchCanvas()
        .task {
            guard ScreenshotFixtures.actionState == nil else { return }
            // #472b review F19: `syncFreshness` is scoped to `OfflineQueue`
            // ALONE, matching `lastSuccessfulSyncAt()`'s own source — joining
            // it with `PendingSessionQueue`'s count (which has no relation to
            // that marker at all, and no retry machinery of its own) made the
            // signal describe something neither queue actually does. The
            // combined `pendingUploads` badge above is unrelated and keeps
            // counting all four queues, same as before.
            async let workouts = OfflineQueue.shared.pendingCount()
            async let sessions = PendingSessionQueue.shared.pendingCount()
            async let lastSync = OfflineQueue.shared.lastSuccessfulSyncAt()
            async let armed = OfflineQueue.shared.isRetryScheduled()
            async let recordings = PendingRecordingQueue.shared.pendingCount()
            // #549 F2: the phone's reported total now includes this queue
            // (`PendingSyncCache`) — the watch's own badge must sum the same
            // four queues, or the two surfaces disagree about a stuck row.
            async let liveWorkoutTerminal = LiveWorkoutTerminalRetry.shared.pendingCount()
            let (workoutCount, sessionCount, recordingCount, syncedAt, isArmed, terminalCount) =
                await (workouts, sessions, recordings, lastSync, armed, liveWorkoutTerminal)
            pendingUploads = workoutCount + sessionCount + recordingCount + terminalCount
            retryScheduled = isArmed
            syncFreshness = SyncFreshnessPolicy.evaluate(
                lastSuccessfulSyncAt: syncedAt,
                hasPending: workoutCount > 0,
                now: Date()
            )
        }
    }

    private func staleSyncMessage(_ lastSuccessfulSyncAt: Date?, retryScheduled: Bool) -> String {
        var base = "Nothing has synced yet"
        if let lastSuccessfulSyncAt {
            let minutes = max(0, Int(Date().timeIntervalSince(lastSuccessfulSyncAt) / 60))
            base = "Last synced \(minutes)m ago"
        }
        // Review F18: only claim an automatic retry is happening when one
        // actually is armed — e.g. NOT true for a signed-out watch, where
        // `drainPass` never even attempts an upload and so never stalls.
        return retryScheduled ? "\(base) — retrying automatically" : base
    }
}
