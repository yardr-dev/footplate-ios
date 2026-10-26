import Foundation

// One followed yard as the models see it: its state, and the calls a
// screen makes, each as the user `/user/me` answered (design 3.5,
// after Android's session/Followed.kt). `Follower` is the app's; the
// model tests give one of their own, over plain state.

@MainActor
protocol Followed: AnyObject {
    var state: YardState { get }

    func observe(_ observer: @escaping @MainActor (YardState) -> Void) -> UUID
    func removeObserver(_ id: UUID)

    /// The newest `limit` letters with `with` older than the seq
    /// `before` (0: the newest of all), oldest first.
    func conversation(with: String, limit: Int64, before: Int64) async throws -> Page

    /// Sends a letter, carrying the files `files` names by the
    /// hash `putBlob` answered; nothing answers, and its `mail`
    /// event follows.
    func mail(to: String, text: String, files: [MailFile]) async throws

    /// Gives the yard a file, so a letter can carry it.
    func putBlob(_ bytes: Data) async throws -> BlobRef

    /// The bytes the yard holds under `hash`: nil for a hash it
    /// holds no more, and for one that is not a 64-character ASCII
    /// SHA-256 hex digest.
    func blob(hash: String) async throws -> Data?

    /// Marks the user's mail read through `through`.
    func ackInbox(through: Int64) async throws

    /// The yard's notices to the user, all the yard keeps.
    func notifications() async throws -> Notifications

    func ackNotifications(through: Int64) async throws

    /// The crew again, on an event that says less than what changed.
    func crew() async throws -> [CrewMember]

    /// The user's decisions again, on a `noted` event.
    func asks() async throws -> Asks
}
