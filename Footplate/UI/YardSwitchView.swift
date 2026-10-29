import SwiftUI

// The yard switch (design 3.5): each paired yard by its name (the
// account's own by the yard's own, a yard of its own by its address's
// host and port) with its waiting count as words or its follow's word,
// the selected one marked by the rust yard line at its left; an
// unreachable yard stays selectable. Pair another yard and Forget this
// yard stand under the rows.
struct YardSwitchView: View {
    var state: InboxState
    var onSelect: (String) -> Void = { _ in }
    var onPairAnother: () -> Void = {}
    var onForget: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.yards, id: \.name) { yard in
                Button {
                    onSelect(yard.name)
                } label: {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(yard.selected ? ThemeColor.accent.color : ThemeColor.surfaceApp.color)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            // A yard of its own is called by its address,
                            // and a long host loses its middle, not the
                            // port that tells two on one host apart.
                            Text(yard.title)
                                .themeType(.label)
                                .foregroundStyle(ThemeColor.textPrimary.color)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(yard.user)
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textSecondary.color)
                        }
                        .padding(.horizontal, 17)
                        Spacer()
                        if let waiting = yard.waiting {
                            Text(waiting)
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textAccent.color)
                                .padding(.trailing, 20)
                        } else if let word = yard.word {
                            Text(word)
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textSecondary.color)
                                .padding(.trailing, 20)
                        }
                    }
                    // At least 64, and as tall as its two lines need. The
                    // yard line takes any height it is offered, so the
                    // row is fixed to its own height, not left a share
                    // of the screen.
                    .frame(minHeight: 64)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 12) {
                Button("Pair another yard") { onPairAnother() }
                    .buttonStyle(FootplateButtonStyle(primary: false))
                Button("Forget this yard") { onForget() }
                    .buttonStyle(FootplateButtonStyle(primary: false))
                if let error = state.error {
                    Text(error)
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textError.color)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Spacer()
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .foregroundStyle(ThemeColor.textPrimary.color)
    }
}
