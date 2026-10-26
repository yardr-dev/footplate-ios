import SwiftUI

// The lines place (design 3.5): the depots as lines with their stages
// and open beads, the travelling totals, in the shared yard chrome.
// Read-only: a bead's row opens nothing, and a backlog stage opens and
// shuts. Pull to refresh reads the board again.
struct LinesScreen: View {
    @Bindable var inbox: InboxModel
    @Bindable var records: Records
    @Bindable var model: LineModel

    var body: some View {
        YardChrome(inbox: inbox, records: records, place: .lines, onPlace: { inbox.place($0) }) {
            content(model.state)
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
                    if state.read {
                        Text(state.head)
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                    if let error = state.error {
                        Text(error)
                            .themeType(.body)
                            .foregroundStyle(ThemeColor.textError.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                    if state.empty {
                        Text("Nothing travels.")
                            .themeType(.body)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 20)
                    }
                    ForEach(state.depots, id: \.name) { depot in
                        depotSection(depot)
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

    private func depotSection(_ depot: LineDepot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(depot.name) · \(depot.travelling) travelling")
                .themeType(.label)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)
            if !depot.error.isEmpty {
                Text(depot.error)
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textError.color)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
            }
            ForEach(depot.flows, id: \.name) { flow in
                flowSection(depot: depot, flow: flow)
            }
            if !depot.elsewhere.isEmpty {
                Text("\(depot.name) · Elsewhere")
                    .themeType(.label)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                ForEach(depot.elsewhere, id: \.id) { bead in
                    beadRow(bead)
                }
            }
        }
    }

    private func flowSection(depot: LineDepot, flow: LineFlow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if depot.flows.count > 1 {
                Text(flow.name)
                    .themeType(.label)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            ForEach(flow.stages, id: \.name) { stage in
                stageSection(depot: depot.name, flow: flow.name, stage: stage)
            }
        }
    }

    @ViewBuilder
    private func stageSection(depot: String, flow: String, stage: LineStage) -> some View {
        if stage.backlog, !stage.open {
            Button {
                model.toggleBacklog(depot: depot, flow: flow, stage: stage.name)
            } label: {
                HStack(spacing: 8) {
                    Text(stage.name)
                        .themeType(.section)
                        .foregroundStyle(ThemeColor.textPrimary.color)
                    Text("\(stage.beads.count) in backlog")
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                    if stage.waits > 0 {
                        Text("· \(stage.waits) wait on you")
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textAccent.color)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
        } else {
            stageHead(depot: depot, flow: flow, stage: stage)
            ForEach(stage.beads, id: \.id) { bead in
                beadRow(bead)
            }
        }
    }

    @ViewBuilder
    private func stageHead(depot: String, flow: String, stage: LineStage) -> some View {
        let head = VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(stage.name)
                    .themeType(.section)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                Spacer()
                if stage.backlog {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
            }
            Text(stage.words)
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        if stage.backlog {
            Button {
                model.toggleBacklog(depot: depot, flow: flow, stage: stage.name)
            } label: {
                head.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            head
        }
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
