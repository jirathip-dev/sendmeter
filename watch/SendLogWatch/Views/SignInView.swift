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
                Text("Sign in with the password you set from the web app (Watch button).")
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
            .padding(.horizontal, 4)
        }
    }
}
