import SwiftUI
import UserNotifications

// The chrome the places share (design 3.5): the head line with the
// selected yard's follow word and the yard switch, then the place's
// own content, then the place bar. A conversation and a decision open
// full screen over their place, without it.
struct YardChrome<Content: View>: View {
    @Bindable var inbox: InboxModel
    @Bindable var records: Records
    var place: Screen
    var onPlace: (Screen) -> Void
    @ViewBuilder var content: Content
    @State private var showingSwitch = false
    @State private var confirmingForget = false
    @State private var askingNotifications = false

    var body: some View {
        let state = inbox.state
        VStack(spacing: 0) {
            headRow(state)
            Divider().overlay(ThemeColor.borderSubtle.color)
            if let error = state.error {
                Text(error)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textError.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            content
            PlaceBar(waiting: state.waiting, current: place, onPlace: onPlace)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .sheet(isPresented: $showingSwitch) {
            YardSwitchView(
                state: state,
                onSelect: { name in
                    inbox.select(name)
                    showingSwitch = false
                },
                onPairAnother: {
                    showingSwitch = false
                    inbox.pairAnother()
                },
                onForget: {
                    showingSwitch = false
                    confirmingForget = true
                }
            )
        }
        .alert("Forget this yard", isPresented: $confirmingForget) {
            Button("Keep", role: .cancel) {}
            Button("Forget", role: .destructive) {
                Task { await inbox.forget() }
            }
        } message: {
            if let sentence = inbox.forgetting() {
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

    private func headRow(_ state: InboxState) -> some View {
        HStack(spacing: 6) {
            Button {
                showingSwitch = true
            } label: {
                HStack(spacing: 6) {
                    Text(state.head)
                        .themeType(.title)
                        .foregroundStyle(ThemeColor.textPrimary.color)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch yard")
            Spacer()
            if let word = state.word {
                if state.action != nil {
                    Button(word) { inbox.act() }
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textAccent.color)
                        .frame(minHeight: 48)
                } else {
                    Text(word)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }
}

/// The places at the foot: Crew and Decide, the waiting count as words
/// beside Decide where any wait. Lines joins it with its own bead.
struct PlaceBar: View {
    var waiting: Int
    var current: Screen
    var onPlace: (Screen) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(ThemeColor.borderSubtle.color)
            HStack(spacing: 0) {
                placeButton("Crew", screen: .crew)
                placeButton("Decide", screen: .decisions, note: waiting > 0 ? "\(waiting) waiting" : nil)
            }
        }
        .background(ThemeColor.surfaceApp.color)
    }

    private func placeButton(_ label: String, screen: Screen, note: String? = nil) -> some View {
        Button {
            onPlace(screen)
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .themeType(.label)
                if let note {
                    Text(note)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textAccent.color)
                }
            }
            .foregroundStyle(current == screen ? ThemeColor.textAccent.color : ThemeColor.textSecondary.color)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
