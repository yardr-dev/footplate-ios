import SwiftUI

// One line opened (design 3.5, after Android's RouteMap): its stations
// from top to bottom on a rail, the track under each coloured by its
// state and dashed where people handle it, the bead cards hanging at
// theirs, and the backlog folded to a count until it is tapped open.
// Pushed onto the lines stack, with the system's back. Read-only: a
// bead card pushes the bead's card. Pull to refresh reads the board
// again.
struct RouteMapScreen: View {
    @Bindable var model: LineModel
    var route: LineRoute

    var body: some View {
        let map = model.routeMap(for: route)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let map {
                    ForEach(Array(map.stations.enumerated()), id: \.element.name) { index, station in
                        StationView(
                            station: station,
                            last: index == map.stations.count - 1,
                            toggle: { model.toggleBacklog(depot: map.depot, flow: map.flow, stage: station.name) },
                            openBead: { model.openBead($0) }
                        )
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await model.refresh() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .navigationTitle(map?.title ?? "\(route.depot) · \(route.flow)")
        .toolbar {
            if let map {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(map.head)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

/// One station: the rail at the left, its head and its bead cards
/// beside it. A backlog shut is its count in place of the cards.
private struct StationView: View {
    var station: Station
    var last: Bool
    var toggle: () -> Void
    var openBead: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if station.backlog, !station.open {
                shutBacklog
            } else {
                head
                ForEach(station.beads, id: \.id) { bead in
                    StationBeadCard(bead: bead) { openBead(bead.id) }
                }
            }
        }
        .padding(.leading, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The overlay is the row's own size, so the track runs on to the
        // next station's dot.
        .overlay(alignment: .topLeading) {
            TrackRail(station: station, last: last)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    /// A station's name with whose group works there; a backlog open
    /// shuts on tap.
    @ViewBuilder
    private var head: some View {
        if station.backlog {
            Button(action: toggle) {
                headLabel(chevron: "chevron.up")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shuts the backlog")
            .accessibilityIdentifier("station/\(station.name)")
        } else {
            headLabel(chevron: nil)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("station/\(station.name)")
        }
    }

    private func headLabel(chevron: String?) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text(station.name)
                    .themeType(.section)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                Text(station.words)
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
            Spacer(minLength: 8)
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// A backlog shut: its name, its count, who waits in it, and the
    /// chevron that opens it.
    private var shutBacklog: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Text(station.name)
                    .themeType(.section)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                Text("\(station.beads.count) in backlog")
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .padding(.leading, 8)
                if station.waits > 0 {
                    Text(" · \(station.waits) wait on you")
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textAccent.color)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the backlog")
        .accessibilityIdentifier("station/\(station.name)")
    }
}

/// The station's dot with the track under it, coloured by the
/// station's state and dashed where people handle it.
private struct TrackRail: View {
    var station: Station
    var last: Bool

    var body: some View {
        let color = stateColor(station.state)
        VStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            if !last {
                track(color)
                    .frame(width: 2)
                    .padding(.top, 4)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func track(_ color: Color) -> some View {
        if station.human {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: size.width, dash: [6, 4]))
            }
        } else {
            Rectangle().fill(color)
        }
    }
}

/// One bead at its station: its id and title, who works it and its
/// stay, and its remark faint where it has one; a tap pushes its card.
/// The card reads as one element.
private struct StationBeadCard: View {
    var bead: StationBead
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(bead.id)
                        .themeType(.code)
                        .foregroundStyle(ThemeColor.textPrimary.color)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !bead.title.isEmpty {
                        Text(bead.title)
                            .themeType(.label)
                            .foregroundStyle(ThemeColor.textPrimary.color)
                            .lineLimit(1)
                    }
                }
                if bead.working {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ThemeColor.statusRunning.color)
                            .frame(width: 8, height: 8)
                        Text(workerWords(bead))
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                    }
                    .padding(.top, 4)
                }
                if let meta = beadMeta(bead) {
                    Text(meta)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                        .padding(.top, bead.working ? 2 : 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(ThemeColor.borderSubtle.color, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityHint("Opens the bead's card")
        .accessibilityIdentifier("bead/\(bead.id)")
    }
}
