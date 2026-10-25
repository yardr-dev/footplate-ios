import SwiftUI

@main
struct FootplateApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            FootplateScene(services: services)
        }
    }
}

/// What the screens share, made once for the process, by hand: no
/// dependency-injection framework. The followers are rebuilt
/// whenever the session or a yard's record changes, since a
/// follower stopped by a refused session is followed again with
/// new clients once the person signs in (design 3.3).
@MainActor
@Observable
final class AppServices {
    let edge: Edge
    let records: Records
    let pairer: Pairer
    let nav: Nav
    let pairModel: PairModel
    let signInModel: SignInModel

    private(set) var followers: [String: Follower] = [:]
    private var yards: Yards?
    private var foreground = false
    private var networkWatch: NetworkWatch?
    private var followSignature: String = ""
    private var recordsObserver: UUID?

    init() {
        let edge: Edge
        do {
            edge = try Edge.live()
        } catch {
            // The built edge is a valid origin by construction; this
            // only stands in where the bundle's is unreadable.
            edge = try! Edge(origin: "https://my.yardr.dev", transport: URLSessionTransport())
        }
        self.edge = edge
        let records = Records.live(origin: edge.origin)
        self.records = records
        let pairer = Pairer(edge: edge, records: records)
        self.pairer = pairer
        let nav = Nav(first: records.kept.yards.isEmpty ? .pair : .crew)
        self.nav = nav
        self.pairModel = PairModel(pairer: pairer, records: records, nav: nav)
        self.signInModel = SignInModel(pairer: pairer, records: records, nav: nav)
        recordsObserver = records.observe { [weak self] _ in
            self?.refollow()
        }
        refollow()
    }

    func start() {
        guard networkWatch == nil else { return }
        let watch = NetworkWatch { [weak self] in
            Task { @MainActor in self?.yards?.noteNetworkChanged() }
        }
        networkWatch = watch
        watch.start()
    }

    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        yards?.foreground = foreground
    }

    var selectedFollower: Follower? {
        guard let selected = records.kept.selected else { return nil }
        return followers[selected]
    }

    private func signature() -> String {
        let kept = records.kept
        let session = kept.account?.session ?? ""
        let yardsPart = kept.yards.map { "\($0.name)=\($0.token)" }.joined(separator: ",")
        return session + "|" + yardsPart
    }

    private func refollow() {
        let next = signature()
        guard next != followSignature else { return }
        followSignature = next
        yards?.close()
        yards = nil
        followers = [:]
        let kept = records.kept
        guard let session = kept.account?.session, !kept.yards.isEmpty else { return }
        let following = Yards(foreground: foreground)
        yards = following
        var made: [String: Follower] = [:]
        for yard in kept.yards {
            if let client = try? edge.yard(device: yard.token, session: session, name: yard.name) {
                made[yard.name] = following.follow(client)
            }
        }
        followers = made
    }
}

private struct FootplateScene: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var services: AppServices

    var body: some View {
        Group {
            switch services.nav.screen {
            case .pair:
                PairScreen(model: services.pairModel, canGoBack: services.nav.canBack, onBack: {
                    if !services.pairModel.back() { services.nav.back() }
                })
            case .signIn(let again):
                SignInScreen(model: services.signInModel, again: again, onBack: { services.nav.back() })
            case .crew:
                CrewScreen(
                    records: services.records,
                    pairer: services.pairer,
                    nav: services.nav,
                    follower: services.selectedFollower
                )
            }
        }
        .tint(ThemeColor.textAccent.color)
        .onAppear(perform: services.start)
        .onChange(of: scenePhase, initial: true) { _, phase in
            services.setForeground(phase == .active)
        }
    }
}
