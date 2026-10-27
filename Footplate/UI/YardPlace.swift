import SwiftUI

// The chrome the places share (design 3.5): the place's title in the
// navigation bar, the yard switch as its leading button, the follow's
// word at its trailing end, the switch as a sheet and Forget as an
// alert. The tab bar and the back button are the system's own.
struct YardPlace: ViewModifier {
    @Bindable var inbox: InboxModel
    var title: String
    @State private var showingSwitch = false
    @State private var confirmingForget = false

    func body(content: Content) -> some View {
        let state = inbox.state
        VStack(spacing: 0) {
            if let notice = state.notice {
                NoticeRow(text: notice) { inbox.dismissNotice() }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
            }
            if let error = state.error {
                Text(error)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textError.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            content
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSwitch = true
                } label: {
                    HStack(spacing: 6) {
                        Text(state.head)
                            .themeType(.body)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(ThemeColor.textPrimary.color)
                }
                .accessibilityLabel("Switch yard")
            }
            if let word = state.word {
                ToolbarItem(placement: .topBarTrailing) {
                    if state.action != nil {
                        Button(word) { inbox.act() }
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textAccent.color)
                    } else {
                        Text(word)
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                    }
                }
            }
        }
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
    }
}

extension View {
    func yardPlace(inbox: InboxModel, title: String) -> some View {
        modifier(YardPlace(inbox: inbox, title: title))
    }
}
