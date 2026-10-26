import SwiftUI
import UserNotifications

// The crew place (design 3.5): the head line with the selected
// yard's follow word, the inbox rows newest letter first with unread
// as words, and the yard switch sheet with each yard's waiting count
// or state word. Tapping a row opens its conversation.
struct CrewScreen: View {
    @Bindable var model: InboxModel
    @Bindable var records: Records
    @Bindable var nav: Nav
    @State private var showingSwitch = false
    @State private var confirmingForget = false
    @State private var askingNotifications = false

    var body: some View {
        let state = model.state
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
            content(state)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .sheet(isPresented: $showingSwitch) {
            YardSwitchView(
                state: state,
                onSelect: { name in
                    model.select(name)
                    showingSwitch = false
                },
                onPairAnother: {
                    showingSwitch = false
                    model.pairAnother()
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
                Task { await model.forget() }
            }
        } message: {
            if let sentence = model.forgetting() {
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
                    Button(word) { model.act() }
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

    @ViewBuilder
    private func content(_ state: InboxState) -> some View {
        if let nothing = state.nothing {
            Text(nothing)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            Spacer()
        } else if state.rows.isEmpty {
            Text("No letters yet.")
                .themeType(.body)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            Spacer()
        } else {
            List {
                ForEach(Array(state.rows.enumerated()), id: \.element.name) { _, row in
                    Button {
                        model.open(row.name)
                    } label: {
                        inboxRow(row)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(ThemeColor.surfaceApp.color)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparatorTint(ThemeColor.borderSubtle.color)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func inboxRow(_ row: Row) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(row.name)
                        .themeType(.label)
                        .foregroundStyle(ThemeColor.textPrimary.color)
                        .lineLimit(1)
                    if let state = row.state {
                        Text(state)
                            .themeType(.meta)
                            .foregroundStyle(row.waiting ? ThemeColor.textAccent.color : ThemeColor.textSecondary.color)
                            .lineLimit(1)
                    }
                }
                if !row.line.isEmpty {
                    Text(row.line)
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if !row.time.isEmpty {
                    Text(row.time)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
                if let unread = row.unread {
                    Text(unread)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textPrimary.color)
                }
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}
