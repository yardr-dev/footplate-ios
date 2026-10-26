import SwiftUI
import UIKit

// The decide place and one decision (design 3.5): the open asks oldest
// first, each a card — the only cards in the app — the weighty lines
// first; then Decided, one line each. One decision is pushed onto the
// place's stack: the weighty lines first, the question, its context
// and the beads it is about, the options with what each costs and the
// recommended one, the words, and Pick, Later and Decline. A run or
// setup ask is approved with Approve behind the unlock. A card the edge
// cannot approve shows what it proposes and the command that answers
// it on the yard's machine, with Copy, in place of Pick or Approve. The
// one secret it can, a harness login's one-time code, takes the code in
// a field that does not echo and Give behind the unlock; the web
// addresses in a card's question and context, the sign-in page among
// them, are links.

/// The decisions list, in the place's own stack.
struct DecisionsScreen: View {
    @Bindable var inbox: InboxModel
    @Bindable var model: DecisionsModel
    @Bindable var decision: DecisionModel
    @Bindable var nav: Nav

    var body: some View {
        NavigationStack(path: $nav.decidePath) {
            list(model.state)
                .yardPlace(inbox: inbox, title: "Decide")
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
        ForEach(Array(state.context.enumerated()), id: \.offset) { _, line in
            linkedText(line)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textPrimary.color)
        }
        ForEach(Array(state.about.enumerated()), id: \.offset) { _, line in
            Text(line)
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
        }
        let picking = state.elsewhere == nil && !state.approvable && !state.givesCode && state.done == nil
        let approving = state.approvable && state.done == nil
        let canChoose = state.unlocking == nil && !state.sending
        if state.approvable {
            options(state, enabled: approving && canChoose)
        }
        ForEach(Array(state.proposes.enumerated()), id: \.offset) { _, line in
            Text(line)
                .themeType(.code)
                .foregroundStyle(ThemeColor.textPrimary.color)
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
        }
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

    /// A line of the asker's words, the web addresses in it links that
    /// the system opens: underlined, in the accent, and so no colour
    /// alone says what is a link.
    private func linkedText(_ line: String) -> Text {
        var words = linked(line)
        for run in words.runs where run.link != nil {
            words[run.range].swiftUI.underlineStyle = .single
            words[run.range].swiftUI.foregroundColor = ThemeColor.textAccent.color
        }
        return Text(words)
    }
}
