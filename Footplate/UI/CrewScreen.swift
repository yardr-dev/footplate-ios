import SwiftUI

// The crew place (design 3.5): the inbox rows newest letter first
// with unread as words, in the shared yard chrome. Tapping a row
// opens its conversation.
struct CrewScreen: View {
    @Bindable var model: InboxModel
    @Bindable var records: Records
    @Bindable var nav: Nav

    var body: some View {
        YardChrome(inbox: model, records: records, place: .crew, onPlace: { model.place($0) }) {
            content(model.state)
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
