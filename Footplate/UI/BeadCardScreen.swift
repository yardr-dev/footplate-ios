import SwiftUI

// One bead opened (design 3.5, after Android's BeadCardView): its title
// and head, the strip of its line with the bead's stage marked, what is
// happening now, Ask the coordinator, the bead's details as the
// yard gave them (its labels, then Media where any note carries a
// picture, its description and notes, newest last), and the bead's page
// in the web view for the rest. Pushed onto the
// lines stack from a card's bead id, a row or a station, with the
// system's back. A place to check and nudge, not to edit. Pull to
// refresh reads the board and the bead again.
struct BeadCardScreen: View {
    @Bindable var model: LineModel
    var route: BeadRoute
    @Environment(\.openURL) private var openURL
    /// The Media grid is pushed over the card.
    @State private var showMedia = false

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
        .navigationDestination(isPresented: $showMedia) {
            MediaGridScreen(model: model, route: route)
        }
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
        ask(card)
        details(card.details)
        if !card.webView.isEmpty {
            web()
        }
        if let error = model.webViewError {
            Text(error)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textError.color)
                .padding(.top, 8)
        }
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

    /// The coordinator's conversation, its draft started with the bead's
    /// id.
    private func ask(_ card: BeadCard) -> some View {
        let coordinator = model.coordinatorName(for: route.yard)
        return Button("Ask \(coordinator)") {
            model.askCoordinator(about: card.bead.id)
        }
        .buttonStyle(FootplateButtonStyle(primary: true))
        .accessibilityHint("Writes to \(coordinator) about this bead")
        .accessibilityIdentifier("bead-ask")
        .padding(.top, 16)
    }

    /// What the Bead call gave: the labels on one line, the description
    /// and the notes, each with its author and time, newest last. The
    /// board's facts above stand while the bead is read; a read that
    /// failed says so here, under what an earlier read gave.
    @ViewBuilder
    private func details(_ details: CardDetails) -> some View {
        if details.loading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Reading the details…")
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
            .padding(.top, 16)
        }
        if !details.labels.isEmpty {
            Text(details.labels.joined(separator: " · "))
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .padding(.top, 16)
                .accessibilityIdentifier("bead-labels")
        }
        let media = details.media
        if !media.isEmpty {
            mediaRow(count: media.count)
        }
        if details.read {
            Text("Description")
                .themeType(.section)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 16)
            if details.body.isEmpty {
                Text("No description.")
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .padding(.top, 8)
            } else {
                linkedText(details.body)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .textSelection(.enabled)
                    .padding(.top, 8)
                    .accessibilityIdentifier("bead-body")
            }
        }
        if !details.notes.isEmpty {
            Text("Notes")
                .themeType(.section)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 16)
            ForEach(Array(details.notes.enumerated()), id: \.offset) { _, note in
                noteRow(note)
            }
        }
        if let error = details.error {
            Text(error)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textError.color)
                .padding(.top, 16)
                .accessibilityIdentifier("bead-details-error")
        }
    }

    /// Every picture of the notes in one grid: a row with their count,
    /// where any note carries one, and the chevron every row that opens
    /// something has.
    private func mediaRow(count: Int) -> some View {
        Button {
            showMedia = true
        } label: {
            HStack(spacing: 8) {
                Text("Media · \(count)")
                    .themeType(.label)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens every picture of the notes")
        .accessibilityIdentifier("bead-media")
        .padding(.top, 8)
    }

    /// One note: who wrote it and when, over its words, which are
    /// selectable with their addresses links, then the pictures and
    /// files it carries.
    private func noteRow(_ note: CardNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(note.author)
                    .themeType(.label)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                if !note.at.isEmpty {
                    Text(note.at)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
            }
            linkedText(note.text)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .textSelection(.enabled)
            if note.carriesFiles {
                NoteFiles(note: note)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    /// The bead's page at the yard's web view, in the phone's browser,
    /// below the details: sessions, mail and the rest live there.
    /// Nothing comes back.
    private func web() -> some View {
        Button("Open in web view") {
            Task {
                if let url = await model.webViewURL(for: route) { openURL(url) }
            }
        }
        .buttonStyle(FootplateButtonStyle(primary: false))
        .disabled(model.resolvingWebView == route)
        .accessibilityHint("Opens the bead's page in the browser")
        .accessibilityIdentifier("bead-open-web")
        .padding(.top, 24)
    }
}
