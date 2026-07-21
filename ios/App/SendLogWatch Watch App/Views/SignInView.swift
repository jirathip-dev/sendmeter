import SwiftUI

struct SignInView: View {
    @Environment(AuthManager.self) private var auth
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("SEND LOG")
                    .font(.headline)

                // Preferred path: pull the session from the paired iPhone so
                // there's no manual login. Shown while we wait for its answer.
                if auth.syncing {
                    VStack(spacing: 6) {
                        ProgressView()
                        Text("Signing in from your iPhone…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("Open Sendmeter on your iPhone if this doesn't finish.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 6)
                    Button("Sign in with email instead") {
                        auth.syncing = false
                    }
                    .font(.footnote)
                } else {
                    signInForm
                }
            }
            .padding(.horizontal, 4)
        }
        // Ask the phone the moment this screen appears (covers the case where
        // bootstrap requested before WCSession finished activating).
        .onAppear { auth.requestSessionFromPhone() }
    }

    @ViewBuilder
    private var signInForm: some View {
        VStack(spacing: 10) {
                Text("Sign in with the password you set from the web app (Watch button), or open Sendmeter on your iPhone to sync automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                SecureField("Password", text: $password)
                    .textContentType(.password)

                if let msg = auth.errorMsg {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    busy = true
                    Task {
                        await auth.signIn(email: email, password: password)
                        busy = false
                    }
                } label: {
                    if busy {
                        ProgressView()
                    } else {
                        Text("Sign In")
                    }
                }
                .disabled(busy || email.isEmpty || password.isEmpty)
        }
    }
}
