import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var mode: Mode = .signIn
    @State private var isWorking = false

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
