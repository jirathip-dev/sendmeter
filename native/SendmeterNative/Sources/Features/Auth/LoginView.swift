import AuthenticationServices
import SendmeterCore
import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var mode: Mode = .signIn
    @State private var isWorking = false
    /// #631: the RAW nonce of the in-flight Apple request — the button's
    /// `onRequest` hashes it for Apple, `onCompletion` hands the raw value
    /// to Supabase (see `AppleAuthNonce`).
    @State private var pendingAppleNonce = ""
    @State private var appleSigningIn = false

    private enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case signUp = "Create Account"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "mountain.2.fill")
                            .font(.system(size: 58, weight: .bold))
                            .foregroundStyle(SendmeterStyle.primary)
                        Text("Sendmeter")
                            .font(.largeTitle.bold())
                        Text("Training load, readiness, climbing workouts, and force measurement in one native app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 36)

                    SurfaceCard {
                        VStack(spacing: 16) {
                            Picker("Mode", selection: $mode) {
                                ForEach(Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                            }
                            .pickerStyle(.segmented)

                            TextField("Email", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(12)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                            SecureField("Password", text: $password)
                                .textContentType(mode == .signIn ? .password : .newPassword)
                                .padding(12)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                            Button {
                                Task {
                                    isWorking = true
                                    defer { isWorking = false }
                                    if mode == .signIn {
                                        await model.signIn(email: email, password: password)
                                    } else {
                                        await model.signUp(email: email, password: password)
                                    }
                                }
                            } label: {
                                HStack {
                                    if isWorking { ProgressView().tint(.white) }
                                    Text(mode.rawValue)
                                }
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .disabled(email.isEmpty || password.count < 6 || isWorking)

                            Divider()

                            Button {
                                Task { await model.signInWithPasskey() }
                            } label: {
                                Label("Sign in with Passkey", systemImage: "person.badge.key.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)

                            // #631: native Sign in with Apple — same
                            // nonce contract as the web: the identity
                            // token carries the SHA-256 hash, Supabase
                            // re-hashes the raw nonce and compares.
                            SignInWithAppleButton(.signIn) { request in
                                let flow = AppleAuthNonce.flow(generator: UUIDAppleNonceGenerator())
                                pendingAppleNonce = flow.raw
                                request.nonce = flow.hashed
                                request.requestedScopes = [.fullName, .email]
                            } onCompletion: { result in
                                switch result {
                                case let .success(authorization):
                                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                                          let token = credential.identityToken,
                                          let tokenString = String(data: token, encoding: .utf8)
                                    else {
                                        model.errorMessage = "Sign in with Apple didn't return an identity token."
                                        return
                                    }
                                    Task {
                                        appleSigningIn = true
                                        await model.signInWithApple(
                                            idToken: tokenString,
                                            rawNonce: pendingAppleNonce
                                        )
                                        appleSigningIn = false
                                    }
                                case let .failure(error):
                                    // Cancellation is expected — stay quiet.
                                    if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                                        model.errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .signInWithAppleButtonStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .disabled(isWorking || appleSigningIn)

                            Button("Email me a magic link") {
                                Task { await model.sendMagicLink(email: email) }
                            }
                            .disabled(email.isEmpty)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }
}

struct PasswordRecoveryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirm)
                        .textContentType(.newPassword)
                } header: {
                    Text("Choose a new password")
                }

                Section {
                    Button("Update Password") {
                        Task { await model.updatePassword(password) }
                    }
                    .disabled(password.count < 8 || password != confirm)
                }
            }
            .navigationTitle("Reset Password")
        }
    }
}
