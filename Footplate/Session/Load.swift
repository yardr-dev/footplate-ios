import Foundation

// What a follower reads before it opens the stream: the calls of design
// 3.3, and no more.
struct Loaded: Equatable, Sendable {
    var me: Me
    var head: Int64
    var settings: Settings
    var user: User
    var crew: [CrewMember]
    var users: [User]
    var inbox: Inbox
    var notifications: Notifications
    var asks: Asks
}

/// How many read letters the inbox is read with, beside the unread.
let readLetters: Int64 = 50

/// The second inbox read's limit: the unread the yard counts, and the
/// newest read beside them. The count is the yard's word, so it is
/// clamped at both ends: a wild one neither overflows the addition
/// (which traps) nor lands on 0, which reads the whole archive.
private func inboxLimit(unread: Int64) -> Int64 {
    min(max(unread, 0), Int64.max - readLetters) + readLetters
}

extension YardClient {
    /// Reads what the screens start from: `/user/me` first, for the user
    /// every later call needs (`actor` and `name` are always the `user` it
    /// answers, 3.1), and the head early, so that what happens meanwhile
    /// comes again from the stream.
    func load() async throws -> Loaded {
        let me = try await me()
        let head = try await head()
        let settings = try await settings()
        let user = try await getUser(name: me.user)
        let crew = try await crew()
        let users = try await users()
        // The count first, then that many and the newest read: the inbox
        // lists the unread before the read, and the rows want the newest
        // letter of each correspondent, read or not.
        var inbox = try await userInbox(name: me.user, limit: 1)
        if !inbox.mail.isEmpty {
            inbox = try await userInbox(name: me.user, limit: inboxLimit(unread: inbox.unread))
        }
        let notifications = try await userNotifications(name: me.user, limit: 0)
        let asks = try await userAsks(name: me.user)
        return Loaded(
            me: me, head: head, settings: settings, user: user, crew: crew,
            users: users, inbox: inbox, notifications: notifications, asks: asks
        )
    }
}
