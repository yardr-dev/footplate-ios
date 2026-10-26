import SwiftUI

// One bead opened (design 3.5, after Android's BeadCardView): its title
// and head, the strip of its line with the bead's stage marked, what is
// happening now, and the two actions: ask the yardmaster about it, or
// open it in the web view. Pushed onto the lines stack from a card's
// bead id, a row or a station, with the system's back. A place to check
// and nudge, not to edit. Pull to refresh reads the board again.
struct BeadCardScreen: View {
    @Bindable var model: LineModel
    var route: BeadRoute
    @Environment(\.openURL) private var openURL

    var body: some View {
        let card = model.card(for: route)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let card {
                    content(card)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .refreshable { await model.refresh() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .navigationTitle(route.bead)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private func content(_ card: BeadCard) -> some View {
        if !card.bead.title.isEmpty {
            Text(card.bead.title)
                .themeType(.title)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
        }
        Text(card.head)
            .themeType(.meta)
            .foregroundStyle(ThemeColor.textSecondary.color)
            .padding(.top, 4)
        // The head already says the stage in words; the strip's colours
        // are for the eyes, as the route map's rail.
        if !card.stages.isEmpty {
            StageStrip(stages: card.stages, marked: card.stage)
                .padding(.top, 12)
                .accessibilityHidden(true)
        }
        now(card.bead)
        actions(card)
    }

    /// What is happening now: who works the bead and its stay, and its
    /// remark, that it waits for a seat and the yard's expected range;
    /// nothing where there is nothing to say.
    @ViewBuilder
    private func now(_ bead: StationBead) -> some View {
        let meta = beadMeta(bead)
        if bead.working || meta != nil {
            Text("Now")
                .themeType(.section)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 16)
            if bead.working {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ThemeColor.statusRunning.color)
                        .frame(width: 8, height: 8)
                    Text(workerWords(bead))
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
                .padding(.top, 8)
            }
            if let meta {
                Text(meta)
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .padding(.top, bead.working ? 2 : 8)
            }
        }
    }

    /// Ask yardmaster and Open in web view, side by side where they fit
    /// and one above the other where they do not.
    private func actions(_ card: BeadCard) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ask(card)
                web(card)
            }
            VStack(spacing: 8) {
                ask(card)
                web(card)
            }
        }
        .padding(.top, 16)
    }

    /// The yardmaster's conversation, its draft started with the bead's
    /// id.
    private func ask(_ card: BeadCard) -> some View {
        Button("Ask yardmaster") {
            model.askYardmaster(about: card.bead.id)
        }
        .buttonStyle(FootplateButtonStyle(primary: true))
        .accessibilityHint("Writes to the yardmaster about this bead")
        .accessibilityIdentifier("bead-ask")
    }

    /// The bead's page at the yard's web view, in the phone's browser:
    /// nothing comes back.
    private func web(_ card: BeadCard) -> some View {
        Button("Open in web view") {
            if let url = URL(string: card.webView) { openURL(url) }
        }
        .buttonStyle(FootplateButtonStyle(primary: false))
        .accessibilityHint("Opens the bead's page in the browser")
        .accessibilityIdentifier("bead-open-web")
    }
}
