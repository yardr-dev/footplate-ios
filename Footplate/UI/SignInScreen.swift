import SwiftUI

// Sign in, design 3.2: the edge's host in meta, the email and the
// password with the password manager's hints, Sign in, Kratos's
// messages under it, the line on where the password goes, and the
// recovery link to the browser. Signing in again asks for the
// password alone.
struct SignInScreen: View {
    @Bindable var model: SignInModel
    var again: Bool = false
    var onBack: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let onBack {
                    Button("Back", action: onBack)
                        .themeType(.label)
                        .foregroundStyle(ThemeColor.textAccent.color)
                        .frame(minHeight: 48, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in")
                        .themeType(.title)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.host)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
                if model.state.again {
                    Text("The session ran out or was revoked. Sign in again as \(model.state.email).")
                        .themeType(.body)
                } else {
                    TextField("Email", text: Binding(
                        get: { model.state.email },
                        set: { model.email($0) }
                    ))
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .themeType(.body)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 48)
                    .background(ThemeColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ThemeColor.borderStrong.color, lineWidth: 1) }
                    .disabled(model.state.busy)
                }
                SecureField("Password", text: Binding(
                    get: { model.state.password },
                    set: { model.password($0) }
                ))
                .textContentType(.password)
                .themeType(.body)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(ThemeColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ThemeColor.borderStrong.color, lineWidth: 1) }
                .disabled(model.state.busy)
                .onSubmit { Task { await model.signIn() } }
                Button(model.state.busy ? "Signing in…" : "Sign in") {
                    Task { await model.signIn() }
                }
                .buttonStyle(FootplateButtonStyle(primary: true))
                .disabled(model.state.busy || model.state.email.trimmingCharacters(in: .whitespaces).isEmpty || model.state.password.isEmpty)
                if let error = model.state.error {
                    Text(error)
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textError.color)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your account at \(model.host). The password is sent there and kept nowhere")
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                    Button("Forgot the password? Recover it at \(model.host)") {
                        if let url = URL(string: model.recovery) { openURL(url) }
                    }
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .underline()
                    .frame(minHeight: 48, alignment: .leading)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .onAppear { model.opened(again: again) }
    }
}
