import SwiftUI
import UIKit
import UserNotifications

@main
struct FootplateApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            FootplateScene(services: services, pushDelegate: pushDelegate)
        }
    }
}

/// The system's push door, which SwiftUI has no shape for: the token
/// the system gives this installation, handed to the registrar. A
/// failure to register is the next launch's to try again; its error
/// is named nowhere, as it can name the token's standing.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    var onToken: @MainActor (String) -> Void = { _ in }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = apnsTokenHex(deviceToken)
        let onToken = self.onToken
        Task { @MainActor in onToken(token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {}
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
    /// The relay's registrations and the stores the wakes share
    /// with the extension: the checkpoints and the wake landings in
    /// the app group, the push token beside the device tokens.
    let registrar: PushRegistrar
    let checkpoints: any CheckpointStore
    let wakeTargets: any WakeTargetStore
    private let notifyDelegate: NotifyDelegate

    /// The demo yard while one is open (Try a demo): a second set of
    /// services, apart from everything above, so that nothing of it is
    /// kept, registered or sent.
    private(set) var demo: Demo?

    private(set) var followers: [String: Follower] = [:]
    private var yards: Yards?
    private var foreground = false
    private var networkWatch: NetworkWatch?
    private var followSignature: String = ""
    private var recordsObserver: UUID?
    private var migrationPendingNames: Set<String> = []
    private var migrationAttemptedSession: String?

    /// The app is made with nothing: the built edge on `URLSession`, the
    /// Keychain and the app group's defaults. The tests give their own
    /// edge, records and secret shelf, to see what a path leaves on them.
    init(edge: Edge? = nil, records: Records? = nil, secret: (any Shelf)? = nil) {
        let edge = edge ?? Self.liveEdge()
        self.edge = edge
        let records = records ?? Records.live(origin: edge.origin)
        self.records = records
        if records.migratedYardName != nil {
            // A yard of its own just moved from "": its delivered
            // notifications still tap there, where the tap would be
            // silently ignored, so they go now, once.
            clearStaleMigratedNotifications()
        }
        // A phone paired before the channel makes its key for
        // each such yard on this launch, kept beside its token and
        // waiting for the yard to take its registration
        // (Records.makeMigrationKeys).
        records.makeMigrationKeys()
        let pairer = Pairer(edge: edge, records: records)
        self.pairer = pairer
        let checkpoints: any CheckpointStore = FileCheckpointStore.shared() ?? MemoryCheckpointStore()
        self.checkpoints = checkpoints
        self.wakeTargets = FileWakeTargetStore.shared() ?? MemoryWakeTargetStore()
        let registrar = PushRegistrar(
            edge: edge, records: records,
            secret: secret ?? KeychainShelf(accessGroup: pushKeychainGroup)
        )
        self.registrar = registrar
        pairer.onForget = { [weak registrar] yard in
            await registrar?.unregister(yard: yard)
        }
        let nav = Nav()
        self.nav = nav
        self.pairModel = PairModel(pairer: pairer, records: records, nav: nav)
        self.signInModel = SignInModel(pairer: pairer, records: records, nav: nav)
        let mailroom = Mailroom()
        self.mailroom = mailroom
        let conversation = ConversationModel(mailroom: mailroom)
        self.conversationModel = conversation
        // The bead card and a decision's details share the pictures
        // their notes carry.
        let notePictures = NotePictures()
        self.decisionsModel = DecisionsModel(records: records, mailroom: mailroom, nav: nav)
        self.decisionModel = DecisionModel(
            mailroom: mailroom, records: records, nav: nav, conversation: conversation,
            unlock: LAUnlockPrompt(), notePictures: notePictures
        )
        self.inboxModel = InboxModel(pairer: pairer, records: records, followers: { [:] }, mailroom: mailroom, nav: nav)
        self.lineModel = LineModel(
            followers: { [:] }, records: records, pairer: pairer, nav: nav, conversation: conversation,
            notePictures: notePictures,
            origins: { [records, edge] name in
                let own = records.kept.yards.first { $0.name == name }?.origin ?? ""
                return own.isEmpty ? edge.origin : own
            }
        )
        self.notifier = Notifier(
            mailroom: mailroom,
            records: records,
            allowed: { await canNotify() },
            tell: { telling in await show(telling) },
            checkpoints: checkpoints
        )
        let wakeTargets = self.wakeTargets
        let delegate = NotifyDelegate(
            onTap: { [weak records, weak nav] yard, target in
                guard let records, let nav else { return }
                applyNotifyTap(yard: yard, target: target, records: records, nav: nav)
            },
            onWakeTap: { [weak records, weak nav] wakeId, kind in
                guard let records, let nav else { return }
                let engine = wakeEngine(edge: edge, records: records, checkpoints: checkpoints, targets: wakeTargets, canSuppress: false)
                await applyWakeTap(wakeId: wakeId, kind: kind, engine: engine, records: records, nav: nav)
            }
        )
        self.notifyDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
        self.inboxModel.followers = { [weak self] in (self?.followers ?? [:]).mapValues { $0 as any Followed } }
        self.lineModel.followers = { [weak self] in (self?.followers ?? [:]).mapValues { $0 as any Followed } }
        recordsObserver = records.observe { [weak self] kept in
            guard let self else { return }
            self.beginMigrationIfNeeded(session: kept.account?.session)
            self.refollow()
            Task { @MainActor in await self.registrar.yardsChanged() }
        }
        beginMigrationIfNeeded(session: records.kept.account?.session)
        refollow()
    }

    /// Registers old pairings before following them. A pending yard is
    /// left out of the followers until its one plain registration call
    /// has answered, so no ordinary device call races the pinning step.
    private func beginMigrationIfNeeded(session: String?) {
        guard let session, migrationAttemptedSession != session else { return }
        migrationAttemptedSession = session
        let candidates = records.kept.yards.filter {
            $0.origin.isEmpty && $0.sealedHow == "in place" && $0.yardChannelPublic == nil
        }
        guard !candidates.isEmpty else { return }
        migrationPendingNames.formUnion(candidates.map(\.name))
        let records = self.records
        let edge = self.edge
        Task { @MainActor [weak self] in
            let refused = await migrateInPlace(records: records, edge: edge, session: session)
            guard let self else { return }
            self.migrationPendingNames.subtract(candidates.map(\.name))
            self.refollow()
            if let yard = refused.first {
                self.nav.notice = "\(yard.title) could not be sealed: the yard refused its channel key. Pair again by QR to seal it."
            }
        }
    }

    private static func liveEdge() -> Edge {
        do {
            return try Edge.live()
        } catch {
            // The built edge is a valid origin by construction; this
            // only stands in where the bundle's is unreadable.
            return try! Edge(origin: "https://my.yardr.dev", transport: URLSessionTransport())
        }
    }

    /// Try a demo: opens the made-up yard over the Pair screen. Nothing of
    /// the app's own is touched, and a demo already open is kept.
    func enterDemo() {
        guard demo == nil else { return }
        demo = Demo(foreground: foreground, leave: { [weak self] in self?.leaveDemo() })
    }

    /// Leaves the demo for the Pair screen: it is shut, and with it
    /// everything it held.
    func leaveDemo() {
        demo?.close()
        demo = nil
    }

    func start() {
        guard networkWatch == nil else { return }
        let watch = NetworkWatch { [weak self] in
            Task { @MainActor in self?.yards?.noteNetworkChanged() }
        }
        networkWatch = watch
        watch.start()
        // The relay's rows are told again on every launch, and the
        // system is asked for the token where it lets footplate
        // notify already (design 8787 3.2).
        Task { await registrar.launch() }
        Task {
            if await canNotify() {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// A push token the system gave, on launch or rotated: the
    /// registrar keeps it and registers every edge yard with it.
    func pushTokenReceived(_ token: String) {
        Task { await registrar.tokenReceived(token) }
    }

    /// A wake link opened: on the yard and row the phone saved
    /// beside its id, or where that landing says, fetching again
    /// where nothing was saved. A link that names no wake of ours
    /// opens the yard list, as it stands.
    func openWake(_ url: URL) {
        let engine = wakeEngine(edge: edge, records: records, checkpoints: checkpoints, targets: wakeTargets, canSuppress: false)
        Task {
            await applyWakeLink(url, engine: engine, records: records, nav: nav)
        }
    }

    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        yards?.foreground = foreground
        demo?.setForeground(foreground)
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

    private func signature(session: String, yards: [PairedYard]) -> String {
        let yardsPart = yards.map { "\($0.name)=\($0.token)@\($0.origin)#\($0.channel != nil)" }.joined(separator: ",")
        return session + "|" + yardsPart
    }

    private func refollow() {
        let kept = records.kept
        let followedYards = kept.yards.filter { !migrationPendingNames.contains($0.name) }
        let session = kept.account?.session
        let next = signature(session: session ?? "", yards: followedYards)
        guard next != followSignature else { return }
        followSignature = next
        yards?.close()
        yards = nil
        followers = [:]
        mailroom.setFollowers([:])
        guard !followedYards.isEmpty, session != nil || followedYards.contains(where: { !$0.origin.isEmpty }) else { return }
        let following = Yards(foreground: foreground)
        // A yard whose owner removed the account is forgotten, in a task
        // of its own: forgetting it follows the yards again.
        following.onRemoved = { [weak self] name, words in
            Task { @MainActor in await self?.inboxModel.removed(name, words) }
        }
        yards = following
        var made: [String: Follower] = [:]
        for yard in followedYards {
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
                client = try? edge.yard(device: yard.token, session: session, name: yard.name, channel: yard.channel)
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
    let pushDelegate: PushAppDelegate

    var body: some View {
        Group {
            if let demo = services.demo {
                DemoTabs(demo: demo, onLeave: { services.leaveDemo() })
            } else if services.records.kept.yards.isEmpty {
                PairScreen(model: services.pairModel, onBack: {
                    _ = services.pairModel.back()
                }, onDemo: { services.enterDemo() })
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
        .onAppear {
            pushDelegate.onToken = { [services] token in services.pushTokenReceived(token) }
            services.start()
        }
        .onOpenURL { url in services.openWake(url) }
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

/// Registers in place every yard paired before the channel
/// (design 3.4 (b), yardr-n9d2): its key, made on this phone and
/// kept beside its token, is registered under its token by the
/// one plain call that still crosses, the yard's channel key is
/// pinned from the answer, and the yard is sealed from then on —
/// the publish rebuilds its client inside the channel. A yard
/// the answer refuses pins nothing, keeps its plain calls as
/// before, and is answered in the result for the app to say so;
/// a yard that merely cannot be reached is not refused, and the
/// next launch asks again. No second registration is made for a
/// yard that stands pinned.
@MainActor
func migrateInPlace(records: Records, edge: Edge, session: String) async -> [PairedYard] {
    var refused: [PairedYard] = []
    for yard in records.kept.yards
    where yard.origin.isEmpty && yard.sealedHow == "in place" && yard.yardChannelPublic == nil {
        guard let channelPrivate = yard.channelPrivate,
              let devicePublic = try? channelPublicOf(channelPrivate),
              let client = try? edge.yard(device: yard.token, session: session, name: yard.name)
        else { continue }
        do {
            let yardPublic = try await client.registerChannelKey(devicePublic: devicePublic)
            records.pinMigrated(name: yard.name, yardPublic: yardPublic)
        } catch let error as ApiError {
            if case .refused = error {
                refused.append(yard)
            }
        } catch {
            continue
        }
    }
    return refused
}
