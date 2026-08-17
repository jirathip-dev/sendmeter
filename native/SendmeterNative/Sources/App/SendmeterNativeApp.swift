import SwiftUI

@main
struct SendmeterNativeApp: App {
    @StateObject private var model = AppModel()
    // #631: the theme choice is read in init — before the first frame —
    // so a saved appearance never flashes the default scheme.
    @StateObject private var theme = AppThemeController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(theme)
                .onOpenURL { url in
                    Task { await model.handleDeepLink(url) }
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
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppThemeController
    @Environment(\.colorScheme) private var systemScheme

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

            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.errorMessage = nil }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toastMessage {
                AppToast(message: toast)
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if model.toastMessage == toast { model.toastMessage = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.errorMessage)
        .animation(.easeInOut(duration: 0.2), value: model.toastMessage)
        .preferredColorScheme(theme.resolvedScheme(prefersDark: systemScheme == .dark))
    }
}

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(AppTab.dashboard)
            WorkoutView()
                .tabItem { Label("Workout", systemImage: "figure.climbing") }
                .tag(AppTab.workout)
            ForceView()
                .tabItem { Label("Force", systemImage: "waveform.path.ecg") }
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

    var body: some View {
        // #662: the shipped Capacitor app's splash — cave backdrop filled to
        // the screen with the separated kangaroo centered on top. Mirrors the
        // web SplashScreen component (src/components/SplashScreen.tsx +
        // src/index.css .splash-*). KEEP-IN-SYNC: if you change either side,
        // update the other (assets live in Resources/Assets.xcassets).
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
                Image("SplashKangaroo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: max(290, min(proxy.size.width * 0.8, 410)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: Color.black.opacity(0.35), radius: 18, y: 16)
                    .accessibilityHidden(true)
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
