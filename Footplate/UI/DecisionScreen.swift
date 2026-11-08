import SwiftUI
import UIKit

// The decide place and one decision (design 3.5): the open asks oldest
// first, each a card — the only cards in the app — the weighty lines
// first; then Decided, one line each. One decision is pushed onto the
// place's stack: the weighty lines first, the question, its context
// (always, its lines in place), its own bead and the beads it is about
// (each a row opening that bead's description and notes), the options with
// what each costs and the recommended one, the words, and Pick, Later and
// Decline, with Ask about this under them while the ask is open. A run or
// setup ask is approved with Approve behind the unlock. A card the edge
// cannot approve shows what it proposes and the command that answers
// it on the yard's machine, with Copy, in place of Pick or Approve. The
// one secret it can, a harness login's one-time code, takes the code in
// a field that does not echo and Give behind the unlock; the web
// addresses in a card's question and context, the sign-in page among
// them, are links. A depot pack too large to read whole is a summary
// card: its sentences are the first screen, each file's line a row that
// opens that file's whole text in a sheet over the card, under its name,
// its action and its SHA-256s.

/// The decisions list, in the place's own stack.
struct DecisionsScreen: View {
    @Bindable var inbox: InboxModel
    @Bindable var model: DecisionsModel
    @Bindable var decision: DecisionModel
    @Bindable var nav: Nav

    var body: some View {
        NavigationStack(path: $nav.decidePath) {
            list(model.state)
                .yardPlace(inbox: inbox, nav: nav, title: "Decide")
                .navigationDestination(for: DecisionRoute.self) { route in
                    DecisionScreen(model: decision, yard: route.yard, bead: route.bead, ask: route.ask)
                }
        }
    }

    @ViewBuilder
    private func list(_ state: DecisionsState) -> some View {
        if state.open.isEmpty, state.decided.isEmpty {
            Text("Nothing waits on you.")
                .themeType(.body)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(state.open.enumerated()), id: \.offset) { _, card in
                        Button {
                            model.open(card)
                        } label: {
                            decisionCard(card)
                        }
                        .buttonStyle(.plain)
                    }
                    if !state.decided.isEmpty {
                        Text("Decided")
                            .themeType(.section)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                            .padding(.top, 12)
                            .padding(.leading, 4)
                        ForEach(Array(state.decided.enumerated()), id: \.offset) { _, line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.question)
                                    .themeType(.body)
                                    .foregroundStyle(ThemeColor.textPrimary.color)
                                    .lineLimit(1)
                                Text(line.what)
                                    .themeType(.meta)
                                    .foregroundStyle(ThemeColor.textSecondary.color)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
    }

    private func decisionCard(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(card.weighty.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .themeType(.label)
                    .foregroundStyle(ThemeColor.textPrimary.color)
            }
            Text(card.title)
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .lineLimit(1)
            Text(card.question)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !card.meta.isEmpty {
                Text(card.meta)
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(ThemeColor.borderSubtle.color, lineWidth: 1) }
        .contentShape(Rectangle())
    }
}

/// One decision, pushed onto the decide stack.
struct DecisionScreen: View {
    @Bindable var model: DecisionModel
    var yard: String
    var bead: String
    var ask: Int64
    @State private var wordsField: String = ""
    @State private var typedField: String = ""
    @State private var declineField: String = ""
    @State private var codeField: String = ""

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if state.read {
                    card(state)
                }
                if let error = state.error {
                    Text(error)
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textError.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .navigationTitle("Decision")
        .toolbar(.hidden, for: .tabBar)
        .onAppear { model.open(yard: yard, bead: bead, ask: ask) }
        .onDisappear { model.leave() }
        // A code the yard refused is not kept in the field.
        .onChange(of: state.givesCode) { _, gives in
            if !gives { codeField = "" }
        }
        // A summary card's text: shut on a swipe down, and gone once the
        // card no longer holds it.
        .sheet(item: Binding(get: { model.state.pack?.text }, set: { if $0 == nil { model.closeText() } })) { text in
            PackTextScreen(text: text)
        }
    }

    @ViewBuilder
    private func card(_ state: DecisionState) -> some View {
        ForEach(Array(state.weighty.enumerated()), id: \.offset) { _, line in
            Text(line)
                .themeType(.label)
                .foregroundStyle(ThemeColor.textPrimary.color)
        }
        linkedText(state.question)
            .themeType(.title)
            .foregroundStyle(ThemeColor.textPrimary.color)
        if !state.context.isEmpty {
            contextLines(state)
        }
        ForEach(Array(state.details.enumerated()), id: \.offset) { _, detail in
            detailsRow(detail)
        }
        let picking = state.elsewhere == nil && !state.approvable && !state.givesCode && state.done == nil
        let approving = state.approvable && state.done == nil
        let canChoose = state.unlocking == nil && !state.sending
        if state.approvable {
            options(state, enabled: approving && canChoose)
        }
        ForEach(Array(state.proposes.enumerated()), id: \.offset) { index, line in
            if let entry = state.pack?.opens[index] {
                textRow(entry) {
                    Text(line)
                        .themeType(.code)
                        .foregroundStyle(ThemeColor.textPrimary.color)
                }
            } else {
                Text(line)
                    .themeType(.code)
                    .foregroundStyle(ThemeColor.textPrimary.color)
            }
        }
        if let more = state.pack?.more, !more.isEmpty {
            Text("More in the full text")
                .themeType(.section)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 8)
            ForEach(more, id: \.self) { entry in
                textRow(entry) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.kind == .source ? "source \(entry.name)" : entry.name)
                            .themeType(.code)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                        Text(entry.action)
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                    }
                }
            }
        }
        if !state.approvable {
            options(state, enabled: picking && canChoose)
        }
        if let done = state.done {
            Text(done)
                .themeType(.label)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .padding(.top, 8)
        } else {
            if let command = state.elsewhere {
                elsewhere(command, state: state)
            }
            if state.givesCode {
                secretField("The code the page gave you", text: $codeField)
                if state.typeBack {
                    field("No screen lock: type \(state.ask) back to give", text: $typedField, mono: true) { model.typed($0) }
                }
                // Give is a tap alone: the field's return goes to nothing.
                Button("Give") {
                    Task { await model.give(code: codeField) }
                }
                .buttonStyle(FootplateButtonStyle(primary: true))
                .disabled(codeField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.sending || state.unlocking != nil)
            }
            if picking {
                let wordsOnly = state.options.isEmpty
                field(wordsOnly ? "Your answer" : "Words to go with it", text: $wordsField) { model.words($0) }
                if state.typeBack {
                    field("No screen lock: type \(state.ask) back to pick", text: $typedField, mono: true) { model.typed($0) }
                }
                Button(wordsOnly ? "Answer" : "Pick") {
                    Task { await model.pick() }
                }
                .buttonStyle(FootplateButtonStyle(primary: true))
                .disabled((wordsOnly ? wordsField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : state.chosen == 0) || state.sending || state.unlocking != nil)
            }
            if approving {
                if state.typeBack {
                    field("No screen lock: type \(state.ask) back to approve", text: $typedField, mono: true) { model.typed($0) }
                }
                // Approve is a tap alone: no field's return goes to it.
                Button("Approve") {
                    Task { await model.approve() }
                }
                .buttonStyle(FootplateButtonStyle(primary: true))
                .disabled((!state.options.isEmpty && state.chosen == 0) || state.sending || state.unlocking != nil)
            }
            if state.declining {
                field("Why not decide it", text: $declineField) { model.declineWords($0) }
            }
            HStack(spacing: 12) {
                Button("Later") {
                    Task { await model.later() }
                }
                .buttonStyle(FootplateButtonStyle(primary: false))
                .disabled(state.sending || state.unlocking != nil)
                Button("Decline") {
                    Task { await model.decline() }
                }
                .buttonStyle(FootplateButtonStyle(primary: false))
                .disabled(state.sending || state.unlocking != nil)
            }
            askButton(state)
        }
    }

    /// Ask about this, secondary like Later: the coordinator's
    /// conversation, its draft started with the bead's id. On a row of
    /// its own, as a third button in the row above leaves its label
    /// about 80 points at 402 and it wraps.
    private func askButton(_ state: DecisionState) -> some View {
        let coordinator = model.coordinatorName(for: yard)
        return Button("Ask about this") {
            model.askCoordinator()
        }
        .buttonStyle(FootplateButtonStyle(primary: false))
        .disabled(state.sending || state.unlocking != nil)
        .accessibilityHint("Writes to \(coordinator) about this bead")
        .accessibilityIdentifier("decision-ask")
    }

    /// The ask's context: its lines in place, always, with their web
    /// addresses links.
    private func contextLines(_ state: DecisionState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(state.context.enumerated()), id: \.offset) { _, line in
                linkedText(line)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textPrimary.color)
            }
        }
    }

    /// One bead the card shows, its own first and then each the ask is
    /// about: shut, its row; tapped open, the bead's description in
    /// place, selectable with its links as the context's are, then its
    /// notes, or its loading or its error.
    private func detailsRow(_ detail: AboutDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await model.toggleDetails(detail.id) }
            } label: {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Details of \(detail.id)")
                            .themeType(.label)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                        if !detailsSecond(detail).isEmpty {
                            Text(detailsSecond(detail))
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textSecondary.color)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 8)
                    Image(systemName: detail.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(detail.expanded ? "Shuts the bead's details" : "Opens the bead's details")
            .accessibilityIdentifier("details/\(detail.id)")
            if detail.expanded {
                if detail.loading {
                    ProgressView()
                        .padding(.vertical, 4)
                } else if let error = detail.error {
                    Text(error)
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textError.color)
                } else if let body = detail.body {
                    if body.isEmpty {
                        Text("No description.")
                            .themeType(.body)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                    } else {
                        linkedText(body)
                            .themeType(.body)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                            .textSelection(.enabled)
                    }
                    if !detail.notes.isEmpty {
                        Text("Notes")
                            .themeType(.section)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 8)
                        ForEach(Array(detail.notes.enumerated()), id: \.offset) { _, note in
                            noteRow(note)
                        }
                    }
                }
            }
        }
    }

    /// One note of the bead a details row opened: who wrote it over its
    /// words, selectable with their web addresses links as the
    /// description's are.
    private func noteRow(_ note: CardNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.author)
                .themeType(.label)
                .foregroundStyle(ThemeColor.textPrimary.color)
            linkedText(note.text)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    /// A details row's second line: the bead's title with its stage.
    private func detailsSecond(_ detail: AboutDetail) -> String {
        [detail.title, detail.stage].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A row of a summary card that opens a text: the line it stands
    /// for, and the chevron every row that opens something has.
    private func textRow<Label: View>(_ entry: PackEntry, @ViewBuilder label: () -> Label) -> some View {
        Button {
            model.openText(entry)
        } label: {
            HStack(spacing: 8) {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the whole text")
        .accessibilityIdentifier("text/\(entry.name)")
    }

    private func elsewhere(_ command: String, state: DecisionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.secretElsewhere {
                Text("This is answered on the yard's machine: a secret never crosses the edge")
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .padding(.top, 8)
            } else if let refusal = state.refusal {
                Text("\(state.secret ? "Not given" : "Not approved"): \(refusal)")
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textError.color)
                    .padding(.top, 8)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(command)
                    .themeType(.code)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    UIPasteboard.general.string = command
                }
                .buttonStyle(FootplateButtonStyle(primary: false))
                .frame(width: 96)
            }
        }
    }

    private func options(_ state: DecisionState, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.options.isEmpty {
                Spacer().frame(height: 4)
            }
            ForEach(Array(state.options.enumerated()), id: \.offset) { _, option in
                Button {
                    model.choose(option.number)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        if enabled {
                            Image(systemName: state.chosen == option.number ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(ThemeColor.textAccent.color)
                                .frame(width: 48, height: 48)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .themeType(.label)
                                .foregroundStyle(ThemeColor.textPrimary.color)
                            if !option.consequence.isEmpty {
                                Text(option.consequence)
                                    .themeType(.body)
                                    .foregroundStyle(ThemeColor.textSecondary.color)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if option.recommended {
                            Text("recommended")
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textAccent.color)
                                .padding(.leading, 12)
                        }
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
            if !state.why.isEmpty {
                Text(state.why)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, mono: Bool = false, onChange: @escaping (String) -> Void) -> some View {
        TextField(label, text: text, axis: .vertical)
            .lineLimit(1...5)
            .themeType(mono ? .code : .body)
            .fieldBox()
            .onChange(of: text.wrappedValue) { _, value in onChange(value) }
    }

    /// A field that does not echo: what is typed in it is a secret, and
    /// goes to the model only as the call's argument.
    private func secretField(_ label: String, text: Binding<String>) -> some View {
        SecureField(label, text: text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .themeType(.body)
            .fieldBox()
    }
}

/// A text of a summary card read whole, over the card: its name, what the
/// import does with it and, of a file, its old and new SHA-256 as the
/// card's line gives them, whole, so that the hash on the line and the
/// hash over the text can be seen to be one. Then the text: a create's,
/// a change's diff with its new text behind it, a source's declaration
/// with each command file under its SHA-256. The lines are drawn lazily,
/// since a file can run to thousands.
struct PackTextScreen: View {
    var text: PackText
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        self.row(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(ThemeColor.textPrimary.color)
            .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
            .navigationTitle(String(text.entry.name.split(separator: "/").last ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("text-done")
                }
            }
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text.entry.name)
                .themeType(.title)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Text(text.entry.kind == .source ? "source, \(text.entry.action)" : text.entry.action)
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .padding(.top, 4)
            if let hashes = text.hashes {
                hash("Old SHA-256", hashes.old.isEmpty ? "(none)" : hashes.old)
                hash("New SHA-256", hashes.new.isEmpty ? "(none)" : hashes.new)
            }
        }
    }

    private func hash(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
            Text(value)
                .themeType(.code)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .textSelection(.enabled)
        }
        .padding(.top, 12)
    }

    /// What the parts of the text are drawn as, one row to a line under one
    /// ForEach: a ForEach of ForEachs, in a LazyVStack in a sheet, left the
    /// lines of a short second part unbuilt (a part of three drew its title
    /// and nothing under it).
    private enum Row {
        case title(String)
        case hash(String)
        case line(PackLine)
        case empty
    }

    private var rows: [Row] {
        text.parts.flatMap { part -> [Row] in
            var rows: [Row] = [.title(part.title)]
            if !part.sha256.isEmpty { rows.append(.hash(part.sha256)) }
            return rows + (part.body.isEmpty ? [.empty] : part.lines.map(Row.line))
        }
    }

    @ViewBuilder
    private func row(_ row: Row) -> some View {
        switch row {
        case .title(let title):
            Text(title)
                .themeType(.section)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24)
                .padding(.bottom, 4)
        case .hash(let sha256):
            hash("SHA-256", sha256)
                .padding(.bottom, 8)
        case .line(let line):
            // An empty line has no height: a space keeps the gap.
            Text(line.text.isEmpty ? " " : line.text)
                .themeType(.code)
                .foregroundStyle(line.quiet ? ThemeColor.textSecondary.color : ThemeColor.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .empty:
            Text("Empty")
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
        }
    }
}
