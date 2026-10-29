import SwiftUI

// The crew place (design 3.5): the inbox rows newest letter first
// with unread as words, in the place's own stack. Tapping a row
// pushes its conversation.
struct CrewScreen: View {
    @Bindable var model: InboxModel
    @Bindable var nav: Nav
    @Bindable var conversation: ConversationModel
    @Bindable var line: LineModel
    @Bindable var notifier: Notifier

    var body: some View {
        NavigationStack(path: $nav.crewPath) {
            VStack(spacing: 0) {
                if notifier.muted {
                    Text("notifications off")
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                }
                content(model.state)
            }
            .yardPlace(inbox: model, nav: nav, title: "Crew")
            .navigationDestination(for: ConversationRoute.self) { route in
                // A chip tapped: the yard's line opens, the bead's card
                // is pushed onto it, and the Lines place shows it.
                ConversationScreen(model: conversation, yard: route.yard, with: route.with, openBead: { id in
                    line.open(yard: route.yard)
                    line.openBead(id)
                    nav.place = .lines
                })
            }
        }
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
