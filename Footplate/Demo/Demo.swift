import Foundation

// The demo yard as the screens have it (Try a demo): the app's own models
// over a yard that lives in the app. It is a second set of services, apart
// from the app's, so a demo is nothing the live ones keep:
//
// - its records lie on two shelves in memory, never the Keychain, and it
//   holds one yard, called `demo`, with a token that opens nothing;
// - its edge is made on `DemoTransport`, which answers in memory, so no
//   request leaves the phone;
// - it has no registrar, no checkpoints and no notification to tell, so
//   nothing is registered with the relay, shared with the extension or put
//   on the lock screen;
// - the pictures a letter sends lie in a folder of its own, taken away
//   with it.
//
// Closing it is leaving it: the follower stops, and nothing is left behind.

@MainActor
final class Demo {
    let nav: Nav
    let records: Records
    let transport: DemoTransport
    let inbox: InboxModel
    let conversation: ConversationModel
    let decisions: DecisionsModel
    let decision: DecisionModel
    let line: LineModel
    // The tabs take these for the covers that pair another yard and sign
    // in, which a demo never shows: leaving it is what pairs a real yard.
    let pair: PairModel
    let signIn: SignInModel
    let notifier: Notifier
    let mailroom: Mailroom

    /// Where the pictures sent in the demo lie, until it is closed.
    let folder: URL

    private let yards: Yards

    /// `leave` is what **Pair a real yard** does: the app shuts the demo and
    /// shows the Pair screen.
    init(
        foreground: Bool = true,
        leave: @escaping @MainActor () -> Void = {},
        transport: DemoTransport = DemoTransport()
    ) {
        self.transport = transport
        // The origin is a constant and valid, as the built edge's is.
        let edge = try! Edge(origin: DemoTransport.origin, transport: transport)
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: edge.origin)
        // A yard of its own in the records' terms: it has an address and
        // wants no session. The token is a word, not a secret.
        let kept = PairedYard(
            name: DemoYard.yard, yard: DemoYard.yard, user: DemoYard.user, device: "phone",
            token: "demo", origin: edge.origin
        )
        records.keepYard(kept)
        // A demo is no pairing: the permission is not asked in it.
        records.noteNotificationsAsked()
        self.records = records

        let nav = Nav()
        self.nav = nav
        let pairer = Pairer(edge: edge, records: records)
        let mailroom = Mailroom()
        self.mailroom = mailroom
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)", isDirectory: true)
        let conversation = ConversationModel(mailroom: mailroom, pictures: Pictures(directory: folder))
        self.conversation = conversation
        decisions = DecisionsModel(records: records, mailroom: mailroom, nav: nav)
        decision = DecisionModel(mailroom: mailroom, records: records, nav: nav, unlock: LAUnlockPrompt())
        inbox = InboxModel(pairer: pairer, records: records, followers: { [:] }, mailroom: mailroom, nav: nav, leave: leave)
        // No web view: a demo bead has no page to open.
        line = LineModel(
            followers: { [:] }, records: records, pairer: pairer, nav: nav, conversation: conversation,
            origins: { _ in "" }
        )
        pair = PairModel(pairer: pairer, records: records, nav: nav)
        signIn = SignInModel(pairer: pairer, records: records, nav: nav)
        // Allowed to tell, with nothing to tell it by: no demo letter
        // reaches the lock screen, and the Crew place shows no
        // `notifications off`.
        let notifier = Notifier(mailroom: mailroom, records: records, allowed: { true }, tell: { _ in })
        self.notifier = notifier

        let following = Yards(foreground: foreground)
        yards = following
        // The client is made on the demo's edge alone, and so on its transport alone.
        let follower = following.follow(try! edge.yardDirect(device: kept.token))
        mailroom.setFollowers([kept.name: follower])
        let followed: [String: any Followed] = [kept.name: follower]
        inbox.followers = { followed }
        line.followers = { followed }
        Task { await notifier.refresh() }
    }

    func setForeground(_ foreground: Bool) {
        yards.foreground = foreground
    }

    /// Leaves the demo: the follower stops, the boards go, and the
    /// pictures sent in it are taken away.
    func close() {
        yards.close()
        mailroom.setFollowers([:])
        try? FileManager.default.removeItem(at: folder)
    }
}
