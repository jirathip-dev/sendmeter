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
    var body: some View {
        ZStack {
            // #662: the shipped Capacitor app's splash — cave backdrop filled
            // to the screen with the separated kangaroo centered on top. Same
            // artwork and layering as the web SplashScreen component.
            Image("SplashCaveBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.17), location: 0),
                    .init(color: .clear, location: 0.44),
                    .init(color: Color.black.opacity(0.35), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            GeometryReader { proxy in
                Image("SplashKangaroo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(proxy.size.width * 0.8, 410))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: Color.black.opacity(0.35), radius: 18, y: 16)
            }
        }
    }
}
