import Foundation
import Observation
import Supabase

@Observable
final class AuthManager {
    enum State {
        case loading
        case signedOut
        case signedIn(userId: UUID)
    }

    var state: State = .loading
    var errorMsg: String?

    private var client: SupabaseClient { SupabaseService.client }

    init() {
        Task { await bootstrap() }
    }

    @MainActor
    func bootstrap() async {
        do {
            let session = try await client.auth.session
            state = .signedIn(userId: session.user.id)
        } catch {
            state = .signedOut
        }
    }

    /// Email + password sign-in. The password is set once from the web app
    /// (Watch button in the top bar); web login itself stays magic-link.
    @MainActor
    func signIn(email: String, password: String) async {
        errorMsg = nil
        do {
            let session = try await client.auth.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            state = .signedIn(userId: session.user.id)
        } catch {
            errorMsg = friendlyAuthError(error)
        }
    }

    @MainActor
    func signOut() async {
        try? await client.auth.signOut()
        state = .signedOut
    }

    private func friendlyAuthError(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("invalid login credentials") {
            return "Wrong email or password. Set the watch password from the web app first (Watch button, top right)."
        }
        return text
    }
}
