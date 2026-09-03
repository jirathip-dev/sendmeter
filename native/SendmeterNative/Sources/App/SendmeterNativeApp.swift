import SendmeterCore
import SendLogWatchCore
import SwiftUI

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
private struct RecoveryInputsFixtureView: View {
    private let metrics: [HealthMetric]

    init() {
        let reference = Date()
        let values: [(Int, Double, Double, Double, Double, Double, Double, Double)] = [
            (13, 42, 61, 13.8, 6.4, 0.9, 1.4, 68.2),
            (12, 48, 59, 14.1, 7.1, 1.1, 1.6, 68.0),
            (11, 55, 57, 13.6, 7.7, 1.3, 1.8, 67.8),
            (10, 61, 56, 13.2, 8.0, 1.5, 1.9, 67.9),
            (9, 58, 55, 13.5, 7.5, 1.2, 1.7, 68.1),
            (8, 64, 54, 13.0, 8.2, 1.6, 2.0, 68.3),
            (7, 60, 53, 13.4, 7.8, 1.4, 1.8, 68.5),
            (6, 67, 52, 12.9, 8.4, 1.7, 2.1, 68.4),
            (5, 63, 51, 13.1, 7.9, 1.5, 1.9, 68.6),
            (4, 70, 50, 12.7, 8.6, 1.8, 2.2, 68.8),
            (3, 66, 49, 12.8, 8.1, 1.6, 2.0, 68.7),
            (2, 72, 48, 12.5, 8.8, 1.9, 2.3, 68.9),
            (1, 69, 47, 12.6, 8.3, 1.7, 2.1, 69.0),
            (0, 75, 46, 12.3, 9.0, 2.0, 2.4, 69.2)
        ]
        metrics = values.enumerated().compactMap { index, value in
            guard index != 5 else { return nil }
            return HealthMetric(
                date: LocalDateSupport.daysAgo(value.0, from: reference, timeZone: .current),
                readiness: nil,
                zone: nil,
                computedAt: reference,
                hrvSDNNMilliseconds: value.1,
                restingHeartRate: value.2,
                sleepHours: value.4,
                sleepDeepHours: value.5,
                sleepREMHours: value.6,
                bodyMassKilograms: value.7,
                respiratoryRate: value.3
            )
        }
    }

    var body: some View {
        RecoveryInputsSheet(fixtureMetrics: metrics)
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
            // mascot tabs, rendered as templates (explicit
            // `.renderingMode(.template)` — the tab bar only tints SF Symbols
            // automatically), tinted in the selected state and grayed when
            // inactive, light and dark.
            //
            // #875 r2 (device reopen): the approved R11 24 px master does not
            // hold a kangaroo-deadlift/barbell read at the real 24 pt tab size
            // (device evidence, umbrella #881). R11 geometry stays frozen; the
            // delivered rendering now presents the SAME approved master as
            // pinned 1x/2x/3x rasters at a 28 pt optical size
            // (r11-force-control-28pt@*.png in ForceMascotTab.imageset; the
            // master SVG remains as the hash-pinned provenance anchor).
            // TabGlyphRenderingWiringTests pins this rendering configuration
            // (template mode, resource wiring, master hash, raster scale).
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
