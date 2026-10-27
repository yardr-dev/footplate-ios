import Foundation
@preconcurrency import UserNotifications

// How a telling is shown: a local notification through
// `UNUserNotificationCenter`, threaded per yard and row, and the tap
// that opens the app on that yard and there. Two Android shapes have
// no iOS counterpart and are not faked: there are no per-kind
// channels, the system's per-app settings being the only control, and
// there is no public lock-screen version — what the lock screen shows
// follows the person's own preview setting (design Q4, decided).

/// Whether a notification would show: the system lets the app, with
/// the alert allowed.
func canNotify(center: UNUserNotificationCenter = .current()) async -> Bool {
    let settings = await center.notificationSettings()
    return (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
        && settings.alertSetting == .enabled
}

/// Shows one telling the system's way: its two lines, now.
func show(_ telling: Telling, center: UNUserNotificationCenter = .current()) async {
    try? await center.add(notificationRequest(telling))
}

/// The request a telling is told with: its two lines, threaded per
/// yard and row, and carrying where a tap leads.
func notificationRequest(_ telling: Telling) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = telling.title
    content.body = telling.body
    content.threadIdentifier = threadOf(telling)
    content.userInfo = userInfoOf(telling)
    content.sound = .default
    return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
}

/// The thread a telling groups under: its yard and its row — the
/// conversation for mail, the card for a decision.
func threadOf(_ telling: Telling) -> String {
    switch telling.target {
    case .conversation(let with):
        return "mail/\(telling.yard)/\(with)"
    case .decision(let bead, let ask):
        return "decision/\(telling.yard)/\(bead)/\(ask)"
    }
}

private let notifyYardKey = "yard"
private let notifyWithKey = "with"
private let notifyBeadKey = "bead"
private let notifyAskKey = "ask"

/// Where a telling leads, as its tap carries it: the yard by its name
/// at the edge, and the conversation or decision there.
func userInfoOf(_ telling: Telling) -> [AnyHashable: Any] {
    var info: [AnyHashable: Any] = [notifyYardKey: telling.yard]
    switch telling.target {
    case .conversation(let with):
        info[notifyWithKey] = with
    case .decision(let bead, let ask):
        info[notifyBeadKey] = bead
        info[notifyAskKey] = ask
    }
    return info
}

/// Where a tap leads: the yard by its name at the edge, and the
/// conversation or decision there. Nil where the tap carries none of
/// ours.
func targetOf(_ userInfo: [AnyHashable: Any]) -> (String, Target)? {
    guard let yard = userInfo[notifyYardKey] as? String else { return nil }
    if let with = userInfo[notifyWithKey] as? String {
        return (yard, .conversation(with: with))
    }
    guard let bead = userInfo[notifyBeadKey] as? String else { return nil }
    let ask: Int64?
    if let number = userInfo[notifyAskKey] as? NSNumber {
        ask = number.int64Value
    } else {
        ask = userInfo[notifyAskKey] as? Int64
    }
    guard let ask, ask >= 0 else { return nil }
    return (yard, .decision(bead: bead, ask: ask))
}

/// A notification's tap: the app on that yard, and on that
/// conversation or decision. A yard paired no more is left where the
/// app opens.
@MainActor
func applyNotifyTap(yard: String, target: Target, records: Records, nav: Nav) {
    guard records.kept.yards.contains(where: { $0.name == yard }) else { return }
    records.select(yard)
    switch target {
    case .conversation(let with):
        nav.place = .crew
        nav.openConversation(yard: yard, with: with)
    case .decision(let bead, let ask):
        nav.place = .decide
        nav.openDecision(yard: yard, bead: bead, ask: ask)
    }
}

/// Whether a delivered notification is the migrated yard's stale one:
/// its tap carries the yard's old name `""`, read through `targetOf`,
/// so only ours with a target. Checked where the records report a
/// migration, when every delivered `""` notification is necessarily
/// the migrated yard's or a forgotten yard's.
func isStaleMigrated(_ request: UNNotificationRequest) -> Bool {
    guard let (yard, _) = targetOf(request.content.userInfo) else { return false }
    return yard.isEmpty
}

/// The delivered requests to remove for that migration. Keeping the
/// selection separate makes the identifiers passed to the system a
/// plain, testable result of the same tap parser.
func staleMigratedNotificationIDs(_ requests: [UNNotificationRequest]) -> [String] {
    requests.filter(isStaleMigrated).map(\.identifier)
}

/// Clears the migrated yard's stale delivered notifications, once, at
/// app start where the records report a migration. Nothing is
/// re-added: a rewritten request would be presented again, and the
/// conversation the stale one told of is still in the app.
func clearStaleMigratedNotifications(center: UNUserNotificationCenter = .current()) {
    center.getDeliveredNotifications { notifications in
        let stale = staleMigratedNotificationIDs(notifications.map(\.request))
        guard !stale.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: stale)
    }
}

/// The center's delegate for the app's tellings: one arrived while
/// the app is open shows as a banner, and a tap opens the app on that
/// yard and there. The tap runs on the main actor; nothing else here
/// touches shared state.
/// A completion the system waits for, called from the main actor
/// once the tap has opened where it leads. The system takes it from
/// any thread, so calling it there races with nothing.
private struct TapCompletion: @unchecked Sendable {
    let completionHandler: () -> Void

    init(_ completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
    }

    func call() {
        completionHandler()
    }
}

final class NotifyDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let onTap: @MainActor (String, Target) -> Void

    init(onTap: @escaping @MainActor (String, Target) -> Void) {
        self.onTap = onTap
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let (yard, target) = targetOf(response.notification.request.content.userInfo) else {
            completionHandler()
            return
        }
        let tap = onTap
        let done = TapCompletion(completionHandler)
        Task { @MainActor in
            tap(yard, target)
            done.call()
        }
    }
}
