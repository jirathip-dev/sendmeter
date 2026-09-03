import Foundation
import SendmeterCore
import SendLogWatchCore
import SwiftUI
import UIKit

@main
struct SendmeterNativeApp: App {
    private let structuralHapticMode: StructuralHapticDiagnosticMode
    private let menuActivationProbe: Bool
    @State private var model: AppModel
    // #631: the theme choice is read in init — before the first frame —
    // so a saved appearance never flashes the default scheme.
    @StateObject private var theme = AppThemeController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        menuActivationProbe = CommandLine.arguments.contains("--menu-activation-probe")
        structuralHapticMode = StructuralHapticDiagnosticMode.resolve(
            arguments: CommandLine.arguments,
            debugBuild: true
        )
        #else
        menuActivationProbe = false
        // Release/TestFlight has no diagnostic parser or opt-in path.
        structuralHapticMode = .normal
        #endif
        let model = AppModel()
        _model = State(wrappedValue: model)
        // #747 slice 4: register before the app finishes launching. The
        // handler owns the BGTask lifecycle and invokes the testable engine
        // body through the same `AppModel`.
        BackgroundSyncService.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if menuActivationProbe {
                    MenuActivationProbeView()
                } else {
                    RootView(structuralHapticMode: structuralHapticMode)
                }
                #else
                RootView(structuralHapticMode: structuralHapticMode)
                #endif
            }
                .buttonStyle(StructuralDefaultButtonStyle(mode: structuralHapticMode))
                .environment(\.structuralHapticTapPolicy, structuralHapticMode.tapPolicy)
                .environment(model)
                .environmentObject(model.forceModel)
                .environmentObject(theme)
                .onOpenURL { url in
                    Task { await model.handleDeepLink(url) }
                }
                // #674 review F7: the orphan sweep also runs once on the
                // root's first appearance — `scenePhase` change delivery on a
                // COLD launch is not guaranteed, so this is the launch-time
                // guarantee that a force-quit-stuck Live Activity is cleared.
                .task {
                    model.reconcileStrandedActivitiesAtLaunch()
                }
                .onChange(of: scenePhase) { phase in
                    // #628: backgrounding clears the keep-awake hold (the
                    // screen must not be pinned while the app can't show
                    // anything); foreground re-derives it from the transport.
                    model.scenePhaseChanged(phase)
                    guard phase == .active else { return }
                    Task { await model.becameActive() }
                }
        }
    }
}

struct RootView: View {
    private let structuralHapticMode: StructuralHapticDiagnosticMode
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var theme: AppThemeController
    @Environment(\.colorScheme) private var systemScheme

    init(structuralHapticMode: StructuralHapticDiagnosticMode = .normal) {
        self.structuralHapticMode = structuralHapticMode
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch model.bootState {
                case .loading:
                    SplashView()
                case .signedOut:
                    #if DEBUG
                    if CommandLine.arguments.contains("--tabs-fixture") {
                        // #875 evidence harness: render the real tab bar
                        // without a signed-in session.
                        TabsFixtureView(selectedTab: fixtureTabArgument())
                    } else if CommandLine.arguments.contains("--recovery-fixture") {
                        RecoveryInputsFixtureView()
                    } else {
                        LoginView()
                    }
                    #else
                    LoginView()
                    #endif
                case .signedIn:
                    if model.passwordRecovery {
                        PasswordRecoveryView()
                    } else {
                        MainTabView()
                    }
                }
            }

        }
        .overlay(alignment: .top) {
            // Stack diagnostics below the error banner so the A/B label can
            // never obscure its message or dismiss button.
            VStack(spacing: 4) {
                if let message = model.errorMessage {
                    ErrorBanner(message: message) { model.errorMessage = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                }

                if let label = structuralHapticMode.displayLabel {
                    StructuralHapticDiagnosticBanner(label: label)
                        .allowsHitTesting(false)
                        .zIndex(20)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                AppToast(message: toast.message, action: toast.action) {
                    model.dismissToast(id: toast.id)
                }
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        do {
                            try await Task.sleep(nanoseconds: toast.timeoutNanoseconds)
                        } catch {
                            return
                        }
                        guard ToastLifecycle.shouldDismiss(
                            currentID: model.toast?.id,
                            callbackID: toast.id
                        ) else { return }
                        model.dismissToast(id: toast.id)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.errorMessage)
        .animation(.easeInOut(duration: 0.2), value: model.toast?.id)
        .preferredColorScheme(theme.resolvedScheme(prefersDark: systemScheme == .dark))
    }
}

#if DEBUG
/// #753 R2 evidence fixture: a deterministic 60-day representative history so
/// the 7d and 28d EWMAs are genuinely warmed before the visible 14-day window
/// (the first-fix fixture supplied only 14 days, so its "28d" line was an
/// immature 13-observation average hugging the bars — which hid the parity
/// defect on device). Values are generated, never sampled: a fixed LCG plus
/// Box–Muller keeps every simulator capture reproducible. Wear gaps at
/// offsets 58, 30, and 8 exercise honest warm-up gaps and a visible-window
/// run split; realistic per-metric ranges and day-to-day noise mix
/// above/near/below-baseline days against the 28d EWMA in every row except
/// weight, which honestly stays neutral near its own average.
private struct RecoveryInputsFixtureView: View {
    private let metrics: [HealthMetric]

    init() {
        let reference = Date()
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextUnit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) & 0xFFFF) / 65_535
        }
        func gauss(_ sigma: Double) -> Double {
            let u1 = max(nextUnit(), 1e-9)
            return sigma * sqrt(-2 * log(u1)) * cos(2 * .pi * nextUnit())
        }
        func wave(_ offset: Int, _ period: Int, _ phase: Int) -> Double {
            sin(2 * .pi * Double(offset + phase) / Double(period))
        }
        func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
            min(max(value, lower), upper)
        }
        let gapOffsets: Set<Int> = [58, 30, 8]
        metrics = (0..<60).compactMap { offset in
            guard !gapOffsets.contains(offset) else { return nil }
            return HealthMetric(
                date: LocalDateSupport.daysAgo(offset, from: reference, timeZone: .current),
                readiness: nil,
                zone: nil,
                computedAt: reference,
                hrvSDNNMilliseconds: clamp(62 + 14 * wave(offset, 34, 0) + gauss(9), 25, 150),
                restingHeartRate: clamp(56 + 6 * wave(offset, 29, 11) + gauss(2.0), 38, 90),
                sleepHours: clamp(7.4 + 0.9 * wave(offset, 31, 19) + gauss(0.7), 3, 12),
                sleepDeepHours: clamp(1.45 + 0.35 * wave(offset, 27, 3) + gauss(0.28), 0.15, 3.2),
                sleepREMHours: clamp(1.75 + 0.45 * wave(offset, 24, 13) + gauss(0.35), 0.2, 4.5),
                bodyMassKilograms: clamp(67.9 + 0.45 * wave(offset, 60, 23) + gauss(0.2), 60, 80),
                respiratoryRate: clamp(13.4 + 0.8 * wave(offset, 23, 7) + gauss(0.45), 9, 19)
            )
        }
    }

    var body: some View {
        RecoveryInputsSheet(fixtureMetrics: metrics)
            .onAppear {
                RecoveryInputsFixtureScroll.scrollToBottomIfRequested()
            }
    }
}

/// #753 R2 evidence: with `--recovery-fixture-scrolled` the sheet scrolls to
/// its bottom so the lower cards (Deep Sleep, REM Sleep, Weight) and the
/// shared axis can be captured. DEBUG-only, launch-argument-gated, and the
/// production sheet is untouched. Retries a few times because the sheet's
/// ScrollView is created after the NavigationStack appears.
private enum RecoveryInputsFixtureScroll {
    static func scrollToBottomIfRequested() {
        guard CommandLine.arguments.contains("--recovery-fixture-scrolled") else { return }
        func scroll() {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else { return }
            var queue = window.subviews
            while let view = queue.popLast() {
                if let scroll = view as? UIScrollView {
                    let bottom = max(
                        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom,
                        0
                    )
                    scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                    return
                }
                queue.append(contentsOf: view.subviews)
            }
        }
        for delay in [0.8, 1.6, 2.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { scroll() }
        }
    }
}
#endif

#if DEBUG
/// #875 evidence harness: presents the real `MainTabView` (tab bar + approved
/// mascots) without a signed-in Supabase session so simulator screenshots can
/// prove tab order and mascot rendering in light and dark. DEBUG-only — the
/// selected tab comes from `--tabs-fixture <name>`; the app's normal
/// signed-in flow never reaches this view.
private struct TabsFixtureView: View {
    private let selectedTab: AppTab
    @Environment(AppModel.self) private var model

    init(selectedTab: AppTab) {
        self.selectedTab = selectedTab
    }

    var body: some View {
        MainTabView()
            .onAppear {
                model.selectedTab = selectedTab
            }
    }
}

private func fixtureTabArgument() -> AppTab {
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: "--tabs-fixture"),
          flagIndex + 1 < args.count
    else { return .dashboard }
    switch args[flagIndex + 1] {
    case "force": return .force
    case "workout": return .workout
    case "history": return .history
    case "settings": return .settings
    default: return .dashboard
    }
}
#endif

private struct StructuralHapticDiagnosticBanner: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.red.opacity(0.9), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.55), lineWidth: 1))
            .accessibilityLabel(label)
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: SendmeterIconSymbol.status.rawValue) }
                .tag(AppTab.dashboard)
            // #875: approved mascot masters replace the SF Symbols on the
            // mascot tabs. The single-scale SVG imagesets render as
            // templates (explicit `.renderingMode(.template)` — the tab bar
            // only tints SF Symbols automatically), tinted in the selected
            // state and grayed when inactive, light and dark.
            ForceView()
                .tabItem {
                    Label {
                        Text("Force")
                    } icon: {
                        Image("ForceMascotTab")
                            .renderingMode(.template)
                    }
                }
                .tag(AppTab.force)
            WorkoutView()
                .tabItem {
                    Label {
                        Text("Workout")
                    } icon: {
                        Image("WorkoutMascotTab")
                            .renderingMode(.template)
                    }
                }
                .tag(AppTab.workout)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .tint(SendmeterStyle.primary)
    }
}

struct SplashView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // #841: the native splash keeps the retired web/Capacitor dyno motion
        // contract in SplashDynoTimeline. The web component is retired; keep
        // this animation's zero phase, transform-only stops, and reduce-motion
        // pose aligned with that historical reference.
        ZStack {
            // Cave backdrop: web `object-fit: cover; object-position: center
            // 57%` (center 64% on ≥720px-wide screens). The image is wider
            // than any phone viewport, so only wide screens (iPad landscape,
            // Slide Over) overflow vertically and the crop offset applies.
            GeometryReader { proxy in
                Image("SplashCaveBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .offset(y: caveCropOffset(container: proxy.size))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea()
            // Web overlay gradient, `--overlay` theme-dependent:
            // light rgba(10,15,25,0.48) -> alphas 0.168 / 0.346,
            // dark rgba(3,6,12,0.68) -> alphas 0.238 / 0.490
            // (src/index.css .splash-screen::after).
            LinearGradient(
                stops: overlayStops,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            // Kangaroo stage: `width: clamp(290px, 80vw, 410px)` (src/index.css
            // .splash-stage). Sized from the full viewport, not the safe area.
            GeometryReader { proxy in
                // Web: `.splash-kangaroo` runs `splash-dyno 4.2s
                // cubic-bezier(0.35, 0, 0.2, 1) infinite` (src/index.css
                // @keyframes splash-dyno), transform-origin 50% 52%. The phase
                // math lives in SplashDynoTimeline (Sources/Core, pinned by
                // SplashDynoTimelineTests); here it is sampled per frame and
                // applied as translation/rotation/scale — transform-only, so
                // the compositor handles it.
                if reduceMotion {
                    // Web reduce-motion sets `animation: none`, which leaves
                    // the element at its base transform — the rest pose.
                    kangaroo(in: proxy, pose: .rest)
                } else {
                    TimelineView(.animation) { context in
                        kangaroo(
                            in: proxy,
                            pose: SplashDynoTimeline.pose(
                                at: context.date.timeIntervalSince(model.splashPresentationDate ?? context.date)
                            )
                        )
                    }
                }
            }
            .ignoresSafeArea()
            VStack {
                Spacer()
                // Loading status for assistive tech and sighted users (the web
                // component labels its container `role="status"` "Starting
                // Sendmeter"; the ProgressView keeps the boot affordance the
                // old splash had).
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("Starting Sendmeter")
                    .padding(.bottom, 24)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            model.splashPresented(at: Date())
        }
    }

    /// The kangaroo at `pose`: scale about the image's (50%, 52%) origin,
    /// rotate about the same origin, then translate by the pose's fractions of
    /// the stage size — the CSS `translate3d() rotate() scale()` chain from
    /// `@keyframes splash-dyno` with `transform-origin: 50% 52%`.
    /// Transform-only: no layout-affecting reads, compositor-friendly.
    private func kangaroo(in proxy: GeometryProxy, pose: SplashDynoPose) -> some View {
        let stage = max(290, min(proxy.size.width * 0.8, 410))
        return Image("SplashKangaroo")
            .resizable()
            .scaledToFit()
            .frame(width: stage)
            .shadow(color: Color.black.opacity(0.35), radius: 18, y: 16)
            .scaleEffect(
                CGSize(width: pose.scaleX, height: pose.scaleY),
                anchor: .init(x: 0.5, y: 0.52)
            )
            .rotationEffect(.degrees(pose.rotationDegrees), anchor: .init(x: 0.5, y: 0.52))
            .offset(x: pose.txFraction * stage, y: pose.tyFraction * stage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var overlayStops: [Gradient.Stop] {
        // Match the web --overlay alpha values for the active appearance.
        let dark = systemScheme == .dark
        let topAlpha: Double = dark ? 0.238 : 0.168
        let bottomAlpha: Double = dark ? 0.490 : 0.346
        return [
            .init(color: .black.opacity(topAlpha), location: 0),
            .init(color: .clear, location: 0.44),
            .init(color: .black.opacity(bottomAlpha), location: 1),
        ]
    }

    /// Reproduces the web `object-position: center p%` crop for a
    /// `cover`-filled backdrop. The cave art is 1080×1920 (aspect 0.5625); a
    /// container wider than that overflows vertically and the offset shifts
    /// the crop to keep the intended portion visible. `p` is 0.57 on phones
    /// (matches 57%), 0.64 on ≥720pt-wide screens (matches 64%).
    ///
    /// `object-position: p%` aligns the image's p% point with the box's p%
    /// point. Centered `cover` shows the middle; moving the anchor away from
    /// 50% shifts the image in the opposite direction (p > 0.5 lifts the crop
    /// upward, negative offset).
    private func caveCropOffset(container size: CGSize) -> CGFloat {
        let artAspect: CGFloat = 1080.0 / 1920.0
        let containerAspect = size.width / max(size.height, 1)
        guard containerAspect > artAspect else { return 0 }
        let p: CGFloat = size.width >= 720 ? 0.64 : 0.57
        let scaledHeight = size.width / artAspect
        return (0.5 - p) * (scaledHeight - size.height)
    }
}
