import SwiftUI

// The lines place (design 3.5): the overview with its stats as
// filters, a card per moving line and the quiet lines' chips, the
// Elsewhere rows and the beads with no line, in the place's own
// stack. Read-only: a line tap does nothing yet, and a card's bead
// ids are plain text. Pull to refresh reads the board again.
struct LinesScreen: View {
    @Bindable var inbox: InboxModel
    @Bindable var records: Records
    @Bindable var model: LineModel

    var body: some View {
        NavigationStack {
            content(model.state)
                .yardPlace(inbox: inbox, title: "Lines")
        }
        .onAppear { openSelected() }
        .onDisappear { model.leave() }
        .onChange(of: records.kept.selected) { _, name in
            if let name { model.open(yard: name) }
        }
    }

    private func openSelected() {
        if let name = records.kept.selected { model.open(yard: name) }
    }

    @ViewBuilder
    private func content(_ state: LineState) -> some View {
        if !state.read, state.error == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = state.error {
                        Text(error)
                            .themeType(.body)
                            .foregroundStyle(ThemeColor.textError.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                    if state.read {
                        statsRow(state)
                    }
                    ForEach(state.lines, id: \.title) { card in
                        lineCard(card)
                    }
                    if !state.quiet.isEmpty {
                        Text("Quiet · \(state.quiet.count)")
                            .themeType(.label)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                            .accessibilityIdentifier("quiet-head")
                        FlowLayout {
                            ForEach(state.quiet, id: \.title) { line in
                                ChipLabel(text: line.title, selected: false)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    if state.empty {
                        Text(state.filter == .all ? "Nothing travels." : "Nothing \(filterWord(state.filter)).")
                            .themeType(.body)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 20)
                    }
                    ForEach(state.depots, id: \.name) { depot in
                        if !depot.error.isEmpty || !depot.elsewhere.isEmpty {
                            Text("\(depot.name) · Elsewhere")
                                .themeType(.label)
                                .foregroundStyle(ThemeColor.textPrimary.color)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                        }
                        if !depot.error.isEmpty {
                            Text(depot.error)
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textError.color)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 4)
                        }
                        ForEach(depot.elsewhere, id: \.id) { bead in
                            beadRow(bead)
                        }
                    }
                    if !state.unassigned.isEmpty {
                        Text("No line")
                            .themeType(.label)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                        ForEach(state.unassigned, id: \.id) { bead in
                            beadRow(bead)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .refreshable { await model.refresh() }
        }
    }

    /// The stats as tappable filters; a stat with none is shown faint
    /// and holds no tap, and the transit count clears the filter.
    private func statsRow(_ state: LineState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                statChip(
                    "\(state.stats.inTransit) in transit", id: "filter-all",
                    selected: state.filter == .all,
                    enabled: state.filter != .all || state.stats.inTransit > 0
                ) {
                    model.filter(.all)
                }
                statChip(
                    "\(state.stats.moving) moving", id: "filter-moving",
                    selected: state.filter == .moving,
                    enabled: state.stats.moving > 0 || state.filter == .moving
                ) {
                    model.filter(state.filter == .moving ? .all : .moving)
                }
                statChip(
                    "\(state.stats.yourTurn) your turn", id: "filter-your-turn",
                    selected: state.filter == .yourTurn,
                    enabled: state.stats.yourTurn > 0 || state.filter == .yourTurn
                ) {
                    model.filter(state.filter == .yourTurn ? .all : .yourTurn)
                }
                statChip(
                    "\(state.stats.held) held", id: "filter-held",
                    selected: state.filter == .held,
                    enabled: state.stats.held > 0 || state.filter == .held
                ) {
                    model.filter(state.filter == .held ? .all : .held)
                }
                statChip(
                    "\(state.stats.late) late", id: "filter-late",
                    selected: state.filter == .late,
                    enabled: state.stats.late > 0 || state.filter == .late
                ) {
                    model.filter(state.filter == .late ? .all : .late)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func statChip(_ label: String, id: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChipLabel(text: label, selected: selected)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One line's card: its lamp, its count, a strip with every stage
    /// the same width, and its beads' ids as plain text.
    private func lineCard(_ card: LineCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let dot = lampColor(card.lamp) {
                    Circle()
                        .fill(dot)
                        .frame(width: 8, height: 8)
                }
                Text(card.title)
                    .themeType(.label)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .lineLimit(1)
                Spacer()
                Text("\(card.inTransit) · \(card.backlog) backlog")
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
            strip(card.stages)
                .padding(.top, 10)
            if !card.beads.isEmpty {
                Text(card.beads.joined(separator: " "))
                    .themeType(.code)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .lineLimit(2)
                    .padding(.top, 8)
                    .accessibilityIdentifier("line-beads/\(card.depot)/\(card.flow)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ThemeColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .accessibilityIdentifier("line/\(card.depot)/\(card.flow)")
    }

    /// The compact stage strip: every stage the same width, each
    /// segment coloured by its state, the stages handled by people
    /// dashed, their names under them.
    private func strip(_ stages: [StripStage]) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(stages, id: \.name) { stage in
                    stripSegment(stage)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 2) {
                ForEach(stages, id: \.name) { stage in
                    Text(stage.name)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func stripSegment(_ stage: StripStage) -> some View {
        let color = stateColor(stage.state)
        if stage.human {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: size.height, dash: [6, 4]))
            }
            .frame(height: 6)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(height: 6)
        }
    }

    /// A state's colour: moving green, your turn accent, broken red,
    /// none the faint line.
    private func stateColor(_ state: StageState) -> Color {
        switch state {
        case .moving: return ThemeColor.statusRunning.color
        case .yourTurn: return ThemeColor.textAccent.color
        case .broken: return ThemeColor.textError.color
        case .none: return ThemeColor.borderSubtle.color
        }
    }

    /// A line card's lamp: its worst state as a dot, nothing where
    /// the line carries none.
    private func lampColor(_ lamp: StageState) -> Color? {
        lamp == .none ? nil : stateColor(lamp)
    }

    private func beadRow(_ bead: LineBead) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(bead.id)
                    .themeType(.code)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .lineLimit(1)
                if !bead.title.isEmpty {
                    Text(bead.title)
                        .themeType(.label)
                        .foregroundStyle(ThemeColor.textPrimary.color)
                        .lineLimit(1)
                }
            }
            if !bead.remark.isEmpty {
                Text(bead.remark)
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
            if bead.working {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ThemeColor.statusRunning.color)
                        .frame(width: 8, height: 8)
                    if let by = bead.workedBy {
                        Text(by)
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 36)
        .padding(.trailing, 20)
        .padding(.vertical, 8)
    }
}

/// A filter chip's label, on a stat button or a quiet line.
private struct ChipLabel: View {
    var text: String
    var selected: Bool

    var body: some View {
        Text(text)
            .themeType(.meta)
            .foregroundStyle(selected ? ThemeColor.textOnAccent.color : ThemeColor.textPrimary.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? ThemeColor.buttonPrimary.color : ThemeColor.surfaceApp.color, in: Capsule())
            .overlay {
                if !selected {
                    Capsule().strokeBorder(ThemeColor.borderStrong.color, lineWidth: 1)
                }
            }
    }
}

/// The filter's word for the empty line: `Nothing moving.`
private func filterWord(_ filter: LineFilter) -> String {
    switch filter {
    case .all: return ""
    case .moving: return "moving"
    case .yourTurn: return "your turn"
    case .held: return "held"
    case .late: return "late"
    }
}

/// Chips left to right, wrapping onto rows.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                height += rowHeight + rowSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : rowWidth, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
