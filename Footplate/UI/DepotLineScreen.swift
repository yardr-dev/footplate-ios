import SwiftUI

// One depot's line (after Android's DetailView): its flows in order
// with their stages, who serves each, each stage file and each group
// prompt behind Read, and the crew's prompts below. Pushed onto the
// lines stack from the route map, with the system's back. Read-only: a
// place to check, not to change. Pull to refresh reads the board and
// the line again.
struct DepotLineScreen: View {
    @Bindable var model: LineModel
    var route: DepotRoute

    var body: some View {
        let detail = model.detail(for: route)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let detail {
                    if detail.reading, detail.line == nil {
                        readingRow
                    }
                    if let error = detail.error {
                        Text(error)
                            .themeType(.body)
                            .foregroundStyle(ThemeColor.textError.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("Detail-error")
                    }
                    if let line = detail.line {
                        ForEach(Array(line.flows.enumerated()), id: \.offset) { index, flow in
                            Text(lineFlowWords(flow))
                                .themeType(.title)
                                .foregroundStyle(ThemeColor.textPrimary.color)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                                .accessibilityIdentifier("Detail-flow/\(index)")
                            ForEach(flow.stages, id: \.stage) { stage in
                                DetailStageView(depot: detail.depot, flow: index, stage: stage, open: detail.open) {
                                    model.toggleDetail($0)
                                }
                            }
                        }
                        if !line.crew.isEmpty {
                            Text("Crew")
                                .themeType(.title)
                                .foregroundStyle(ThemeColor.textPrimary.color)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                                .accessibilityIdentifier("Detail-crew-head")
                            ForEach(line.crew, id: \.name) { member in
                                DetailCrewView(depot: detail.depot, member: member, open: detail.open) {
                                    model.toggleDetail($0)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await model.refresh() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .navigationTitle("\(route.depot) · line")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private var readingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Reading the line…")
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityIdentifier("Detail-reading")
    }
}

/// One stage of the detail: its name with who serves it, its stage
/// file behind Read where it has one, and each of its chain's groups'
/// prompts behind Read.
private struct DetailStageView: View {
    var depot: String
    var flow: Int
    var stage: DepotLineStage
    var open: Set<String>
    var toggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(stage.stage)
                .themeType(.section)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("Detail-stage/\(flow)/\(stage.stage)")
            Text(lineServed(stage))
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
            if let file = stage.stageFile {
                let key = detailFileKey(depot: depot, flow: flow, stage: stage.stage)
                DetailTextRow(
                    head: "Stage file · \(file.path)",
                    text: file.text,
                    open: open.contains(key),
                    key: key,
                    onToggle: { toggle(key) }
                )
            }
            ForEach(stage.route?.chain ?? [], id: \.name) { group in
                DetailGroupPromptView(depot: depot, flow: flow, stage: stage.stage, group: group, open: open, toggle: toggle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

/// One chain group's prompt: its row behind Read, or the reason it
/// has none where the read answers no prompt for it.
private struct DetailGroupPromptView: View {
    var depot: String
    var flow: Int
    var stage: String
    var group: DepotLineGroup
    var open: Set<String>
    var toggle: (String) -> Void

    var body: some View {
        if let prompt = group.prompt {
            let key = detailPromptKey(depot: depot, flow: flow, stage: stage, group: group.name)
            DetailPromptRow(
                head: linePromptHead(prompt, group: group.name),
                prompt: prompt,
                open: open.contains(key),
                key: key,
                onToggle: { toggle(key) }
            )
        } else {
            Text("Prompt · \(group.name) · \(lineNoPromptWords(group))")
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .accessibilityIdentifier("Detail-noprompt/\(flow)/\(stage)/\(group.name)")
        }
    }
}

/// One crew member: its name, its prompt behind Read where its config
/// names one, and none where it names none.
private struct DetailCrewView: View {
    var depot: String
    var member: DepotLineCrew
    var open: Set<String>
    var toggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(member.name)
                .themeType(.label)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .accessibilityIdentifier("Detail-crew/\(member.name)")
            if let prompt = member.prompt {
                let key = detailCrewKey(depot: depot, name: member.name)
                DetailPromptRow(
                    head: linePromptHead(prompt),
                    prompt: prompt,
                    open: open.contains(key),
                    key: key,
                    onToggle: { toggle(key) }
                )
            } else {
                Text("no prompt")
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// A prompt's row: its head with Read for its text, or why its text
/// is not shown where the read could not read it, in the text's
/// place.
private struct DetailPromptRow: View {
    var head: String
    var prompt: DepotLinePrompt
    var open: Bool
    var key: String
    var onToggle: () -> Void

    var body: some View {
        let error = linePromptError(prompt)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(head)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                if error == nil {
                    ReadButton(key: key, onToggle: onToggle)
                }
            }
            if let error {
                Text(error)
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .padding(.top, 4)
                    .accessibilityIdentifier("Detail-unread/\(key)")
            } else if open {
                Text(prompt.text)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                    .accessibilityIdentifier("Detail-text/\(key)")
            }
        }
        .padding(.top, 8)
    }
}

/// A stage file's row: its head with Read for its text.
private struct DetailTextRow: View {
    var head: String
    var text: String
    var open: Bool
    var key: String
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(head)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                ReadButton(key: key, onToggle: onToggle)
            }
            if open {
                Text(text)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                    .accessibilityIdentifier("Detail-text/\(key)")
            }
        }
        .padding(.top, 8)
    }
}

/// The Read that opens a text where shut and shuts it where open.
/// A phone's touch target, 48pt at its smallest, which no head
/// squeezes: the head takes the row's width and wraps, the Read its
/// own.
private struct ReadButton: View {
    var key: String
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text("Read")
                .themeType(.label)
                .foregroundStyle(ThemeColor.textAccent.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 48, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("Detail-read/\(key)")
    }
}
