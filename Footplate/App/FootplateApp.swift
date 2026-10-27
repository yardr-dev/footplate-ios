import SwiftUI
import UserNotifications

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
    let lineModel: LineModel
    let notifier: Notifier
    private let notifyDelegate: NotifyDelegate

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
        let nav = Nav()
        self.nav = nav
        self.pairModel = PairModel(pairer: pairer, records: records, nav: nav)
        self.signInModel = SignInModel(pairer: pairer, records: records, nav: nav)
        let mailroom = Mailroom()
        self.mailroom = mailroom
        let conversation = ConversationModel(mailroom: mailroom)
        self.conversationModel = conversation
        self.decisionsModel = DecisionsModel(records: records, mailroom: mailroom, nav: nav)
        self.decisionModel = DecisionModel(mailroom: mailroom, records: records, nav: nav, unlock: LAUnlockPrompt())
        self.inboxModel = InboxModel(pairer: pairer, records: records, followers: { [:] }, mailroom: mailroom, nav: nav)
        self.lineModel = LineModel(
            followers: { [:] }, records: records, pairer: pairer, nav: nav, conversation: conversation,
            origins: { [records, edge] name in
                let own = records.kept.yards.first { $0.name == name }?.origin ?? ""
                return own.isEmpty ? edge.origin : own
            }
        )
        self.notifier = Notifier(
            mailroom: mailroom,
            records: records,
            allowed: { await canNotify() },
            tell: { telling in await show(telling) }
        )
        let delegate = NotifyDelegate { [weak records, weak nav] yard, target in
            guard let records, let nav else { return }
            applyNotifyTap(yard: yard, target: target, records: records, nav: nav)
        }
        self.notifyDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
        self.inboxModel.followers = { [weak self] in (self?.followers ?? [:]).mapValues { $0 as any Followed } }
        self.lineModel.followers = { [weak self] in (self?.followers ?? [:]).mapValues { $0 as any Followed } }
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

    /// What the screen shows, as far as a notification cares: what
    /// arrives on it is read where it stands.
    func syncShown() {
        notifier.show(shownOf(place: nav.place, crewPath: nav.crewPath, decidePath: nav.decidePath, selected: records.kept.selected))
    }

    var selectedFollower: Follower? {
        guard let selected = records.kept.selected else { return nil }
        return followers[selected]
    }

    private func signature() -> String {
        let kept = records.kept
        let session = kept.account?.session ?? ""
        let yardsPart = kept.yards.map { "\($0.name)=\($0.token)@\($0.origin)" }.joined(separator: ",")
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
        let session = kept.account?.session
        guard !kept.yards.isEmpty, session != nil || kept.yards.contains(where: { !$0.origin.isEmpty }) else { return }
        let following = Yards(foreground: foreground)
        yards = following
        var made: [String: Follower] = [:]
        for yard in kept.yards {
            // An edge yard without a session is followed nowhere: the
            // inbox asks for the sign-in, and the yards are followed
            // again with new clients once it is kept. A yard of its
            // own needs no session.
            let client: YardClient?
            if !yard.origin.isEmpty {
                // A yard of its own is the app's client at its
                // address: the timeouts and what TLS trusts are the
                // client's.
                client = try? Edge(origin: yard.origin, transport: edge.transport).yardDirect(device: yard.token)
            } else if let session {
                client = try? edge.yard(device: yard.token, session: session, name: yard.name)
            } else {
                client = nil
            }
            if let client {
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
            if services.records.kept.yards.isEmpty {
                PairScreen(model: services.pairModel, onBack: {
                    _ = services.pairModel.back()
                })
                .fullScreenCover(isPresented: signInShown) {
                    SignInScreen(model: services.signInModel, again: services.nav.signIn?.again ?? false, onBack: {
                        services.nav.signIn = nil
                    })
                }
            } else {
                TabsView(
                    nav: services.nav,
                    inbox: services.inboxModel,
                    records: services.records,
                    conversation: services.conversationModel,
                    decisions: services.decisionsModel,
                    decision: services.decisionModel,
                    line: services.lineModel,
                    pair: services.pairModel,
                    signIn: services.signInModel,
                    notifier: services.notifier
                )
            }
        }
        .tint(ThemeColor.textAccent.color)
        .onAppear(perform: services.start)
        .onChange(of: scenePhase, initial: true) { _, phase in
            services.setForeground(phase == .active)
            if phase == .active {
                services.syncShown()
                Task { await services.notifier.refresh() }
            }
        }
        .onChange(of: services.nav.place) { _, _ in services.syncShown() }
        .onChange(of: services.nav.crewPath) { _, _ in services.syncShown() }
        .onChange(of: services.nav.decidePath) { _, _ in services.syncShown() }
        .onChange(of: services.records.kept.selected) { _, _ in services.syncShown() }
    }

    /// Sign in over the Pair root.
    private var signInShown: Binding<Bool> {
        Binding(
            get: { services.nav.signIn != nil },
            set: { if !$0 { services.nav.signIn = nil } }
        )
    }
}
