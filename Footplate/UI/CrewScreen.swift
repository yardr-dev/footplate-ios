import SwiftUI
import UserNotifications

// The crew place B4 opens: empty, with the head line, the yard
// switch with Pair another yard and Forget this yard, and the
// notifications permission asked once after the first pairing.
// B5 fills the rows; the head line and the switch are B4's.
struct CrewScreen: View {
    @Bindable var records: Records
    var pairer: Pairer
    @Bindable var nav: Nav
    /// The selected yard's follower, where the app follows it: its
    /// word where it is not up.
    var follower: Follower?
    @State private var showingSwitch = false
    @State private var confirmingForget = false
    @State private var forgetError: String?
    @State private var askingNotifications = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button {
                    showingSwitch = true
                } label: {
                    HStack {
                        Text(head)
                            .themeType(.title)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                        Spacer()
                        if let word {
                            Text(word)
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textAccent.color)
                        }
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch yard")
                if word != nil, let actionLabel {
                    Button(actionLabel) { act() }
                        .buttonStyle(FootplateButtonStyle(primary: false))
                }
                Text("No letters yet.")
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                if let forgetError {
                    Text(forgetError)
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textError.color)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .sheet(isPresented: $showingSwitch) {
            yardSwitch
        }
        .alert("Forget this yard", isPresented: $confirmingForget) {
            Button("Keep", role: .cancel) {}
            Button("Forget", role: .destructive) {
                Task { await forget() }
            }
        } message: {
            if let sentence = forgettingSentence {
                Text(sentence)
            }
        }
        .alert("Notifications", isPresented: $askingNotifications) {
            Button("Continue") {
                records.noteNotificationsAsked()
                Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            }
        } message: {
            Text("footplate tells you of letters and decisions while it is open, if you allow it.")
        }
        .onAppear {
            if !records.notificationsAsked, !records.kept.yards.isEmpty {
                askingNotifications = true
            }
        }
    }

    private var head: String {
        guard let yard = records.kept.selectedYard else { return "" }
        return "\(yard.title) · \(yard.user)"
    }

    private var word: String? {
        if records.kept.account == nil { return "sign in again" }
        guard let follower else { return nil }
        switch follower.state.status {
        case .down(_, let short): return short
        case .pairAgain: return "pair again"
        case .signInAgain: return "sign in again"
        case .starting, .up: return nil
        }
    }

    private var actionLabel: String? {
        if records.kept.account == nil { return "Sign in again" }
        guard let follower else { return nil }
        switch follower.state.status {
        case .pairAgain: return "Pair again"
        case .signInAgain: return "Sign in again"
        default: return nil
        }
    }

    private func act() {
        if records.kept.account == nil {
            nav.show(.signIn(again: true))
            return
        }
        guard let follower else { return }
        switch follower.state.status {
        case .pairAgain: nav.show(.pair)
        case .signInAgain: nav.show(.signIn(again: true))
        default: break
        }
    }

    private var forgettingSentence: String? {
        guard let yard = records.kept.selectedYard else { return nil }
        return "footplate forgets \(yard.title). The device stays at the yard until its operator runs yardr user device rm \(yard.user) \(yard.device)"
    }

    private func forget() async {
        guard let name = records.kept.selected else { return }
        forgetError = nil
        do {
            try await pairer.forget(name: name)
        } catch let api as ApiError {
            forgetError = "The edge did not end the session: \(words(api))"
        } catch {
            forgetError = "The edge did not end the session: \(error)"
        }
        if records.kept.yards.isEmpty {
            nav.reset(.pair)
        }
    }

    private var yardSwitch: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch yard")
                .themeType(.section)
            ForEach(records.kept.yards, id: \.name) { yard in
                Button {
                    records.select(yard.name)
                    showingSwitch = false
                } label: {
                    HStack {
                        Text("\(yard.title) · \(yard.user)")
                            .themeType(.body)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                        Spacer()
                        if yard.name == records.kept.selected {
                            Text("selected")
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textSecondary.color)
                        }
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button("Pair another yard") {
                showingSwitch = false
                nav.show(.pair)
            }
            .buttonStyle(FootplateButtonStyle(primary: true))
            Button("Forget this yard") {
                showingSwitch = false
                confirmingForget = true
            }
            .buttonStyle(FootplateButtonStyle(primary: false))
            if let forgetError {
                Text(forgetError)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textError.color)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: 480, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .foregroundStyle(ThemeColor.textPrimary.color)
    }
}
