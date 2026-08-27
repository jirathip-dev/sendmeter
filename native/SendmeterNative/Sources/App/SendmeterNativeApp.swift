import SendmeterCore
import SendLogWatchCore
import SwiftUI

@main
struct SendmeterNativeApp: App {
    private let structuralHapticMode: StructuralHapticDiagnosticMode
    @State private var model: AppModel
    // #631: the theme choice is read in init — before the first frame —
    // so a saved appearance never flashes the default scheme.
    @StateObject private var theme = AppThemeController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        structuralHapticMode = StructuralHapticDiagnosticMode.resolve(
            arguments: CommandLine.arguments,
            debugBuild: true
        )
        #else
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
            RootView(structuralHapticMode: structuralHapticMode)
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
                    LoginView()
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
            WorkoutView()
                .tabItem { Label("Workout", systemImage: SendmeterIconSymbol.workout.rawValue) }
                .tag(AppTab.workout)
            ForceView()
                .tabItem { Label("Force", systemImage: SendmeterIconSymbol.force.rawValue) }
                .tag(AppTab.force)
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
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // #662: the shipped Capacitor app's splash — cave backdrop filled to
        // the screen with the separated kangaroo centered on top. Mirrors the
        // web SplashScreen component (src/components/SplashScreen.tsx +
        // src/index.css .splash-*). KEEP-IN-SYNC: if you change either side,
        // update the other (assets live in Resources/Assets.xcassets, motion
        // values in SplashDynoTimeline; the web side carries the twin
        // KEEP-IN-SYNC comment in SplashScreen.tsx).
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
                                at: context.date.timeIntervalSinceReferenceDate
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
