import SwiftUI

struct RootView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(TindeqManager.self) private var tindeq

    var body: some View {
        @Bindable var tindeq = tindeq
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            SignInView()
        case .signedIn:
            NavigationStack {
                HomeView()
            }
            // Finish-gauge-session prompt lives at the root so it surfaces even
            // when the Progressor drops after leaving the Force screen (SL-58 #5).
            .sheet(isPresented: $tindeq.pendingFinish) {
                GaugeFinishSheet()
            }
        }
    }
}
