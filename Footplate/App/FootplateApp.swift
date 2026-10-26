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
    let mailroom: Mailroom
    let inboxModel: InboxModel
    let conversationModel: ConversationModel
    let decisionsModel: DecisionsModel
    let decisionModel: DecisionModel

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
        let mailroom = Mailroom()
        self.mailroom = mailroom
        self.conversationModel = ConversationModel(mailroom: mailroom)
        self.decisionsModel = DecisionsModel(records: records, mailroom: mailroom, nav: nav)
        self.decisionModel = DecisionModel(mailroom: mailroom, records: records, nav: nav, unlock: LAUnlockPrompt())
        self.inboxModel = InboxModel(pairer: pairer, records: records, followers: { [:] }, mailroom: mailroom, nav: nav)
        self.inboxModel.followers = { [weak self] in (self?.followers ?? [:]).mapValues { $0 as any Followed } }
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
        mailroom.setFollowers([:])
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
        mailroom.setFollowers(made.mapValues { $0 as any Followed })
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
                    model: services.inboxModel,
                    records: services.records,
                    nav: services.nav
                )
            case .conversation(let yard, let with):
                ConversationScreen(
                    model: services.conversationModel,
                    yard: yard,
                    with: with,
                    onBack: { services.nav.back() }
                )
            case .decisions:
                DecisionsScreen(
                    inbox: services.inboxModel,
                    records: services.records,
                    model: services.decisionsModel
                )
            case .decision(let yard, let bead, let ask):
                DecisionScreen(
                    model: services.decisionModel,
                    yard: yard,
                    bead: bead,
                    ask: ask,
                    onBack: { services.nav.back() }
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
