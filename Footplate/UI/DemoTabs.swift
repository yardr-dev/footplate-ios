import SwiftUI

// The tabs over the demo yard (Try a demo): the same three places, under a
// banner on every screen that says plainly the yard is made up, with the
// way out to pairing beside it.
struct DemoTabs: View {
    var demo: Demo
    var onLeave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DemoBanner(onLeave: onLeave)
            TabsView(
                nav: demo.nav, inbox: demo.inbox, records: demo.records, conversation: demo.conversation,
                decisions: demo.decisions, decision: demo.decision, line: demo.line, pair: demo.pair,
                signIn: demo.signIn, notifier: demo.notifier
            )
        }
    }
}

/// What the demo says of itself: one quiet row above the places, a
/// hairline under it, and **Pair a real yard** to leave.
struct DemoBanner: View {
    var onLeave: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The words and the button side by side, and one over the other
        // where the text is too large for both to have room.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        VStack(spacing: 0) {
            layout {
                Text("Demo yard: the crew, mail and beads are made up, and nothing leaves this phone")
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Pair a real yard", action: onLeave)
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textAccent.color)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("demo-leave")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
            Rectangle()
                .fill(ThemeColor.borderSubtle.color)
                .frame(height: 1)
        }
        .background(ThemeColor.surfaceRaised.color.ignoresSafeArea(edges: .top))
        .accessibilityElement(children: .contain)
    }
}
