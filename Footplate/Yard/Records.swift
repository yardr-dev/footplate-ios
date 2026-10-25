import Foundation
import Security

// The records of design 3.2: one for the account and its session, one
// per paired yard and its device token, and the selected yard's name.
// Both tokens live in the Keychain (ThisDeviceOnly, never
// synchronised); the origin, the names, the account and the selection
// are not secret and live on the plain shelf.

/// Where a few strings lie, by key. The app's secret shelf is the
/// Keychain and its plain shelf is `UserDefaults`; the tests hold a
/// map, since the gate runs on the simulator alone.
protocol Shelf: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func keys() -> Set<String>
    /// Writes every pair of `put` and drops every key of `remove`, at once.
    func write(put: [String: String], remove: [String])
}

extension Shelf {
    func write(put: [String: String] = [:], remove: [String] = []) {
        write(put: put, remove: remove)
    }
}

/// A shelf in memory: the tests', and a preview's.
final class MemoryShelf: Shelf, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    var map: [String: String] {
        lock.withLock { values }
    }

    func get(_ key: String) -> String? {
        lock.withLock { values[key] }
    }

    func keys() -> Set<String> {
        lock.withLock { Set(values.keys) }
    }

    func write(put: [String: String], remove: [String]) {
        lock.withLock {
            for key in remove { values.removeValue(forKey: key) }
            for (key, value) in put { values[key] = value }
        }
    }
}

/// The Keychain as the secret shelf: `kSecClassGenericPassword`, one
/// account value per record, `WhenUnlockedThisDeviceOnly` and never
/// synchronised, so no token reaches iCloud Keychain, a backup or
/// another device.
final class KeychainShelf: Shelf, @unchecked Sendable {
    static let service = "dev.yardr.footplate"

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
    }

    func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func keys() -> Set<String> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    func write(put: [String: String], remove: [String]) {
        for key in remove {
            SecItemDelete(baseQuery(key) as CFDictionary)
        }
        for (key, value) in put {
            let data = Data(value.utf8)
            var query = baseQuery(key)
            query[kSecAttrSynchronizable as String] = false
            let update: [String: Any] = [kSecValueData as String: data]
            if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                add[kSecAttrSynchronizable as String] = false
                SecItemAdd(add as CFDictionary, nil)
            }
        }
    }
}

/// `UserDefaults` as the plain shelf, its keys namespaced so the
/// records' keys are the only ones this shelf names.
final class UserDefaultsShelf: Shelf, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = "dev.yardr.footplate.records."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func get(_ key: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    func keys() -> Set<String> {
        Set(defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) })
    }

    func write(put: [String: String], remove: [String]) {
        for key in remove { defaults.removeObject(forKey: prefix + key) }
        for (key, value) in put { defaults.set(value, forKey: prefix + key) }
    }
}

/// The account signed in at the edge: `origin` the edge it was signed
/// in at, `account` the email or handle it signed in as, `session`
/// the token Kratos answered.
struct Account: Equatable, Sendable {
    var origin: String
    var account: String
    var session: String
}

extension Account: CustomStringConvertible {
    var description: String { "Account(\(origin), \(account), session=<token>)" }
}

/// One paired yard: `name` its name at the edge (empty: the account's
/// own, and no `X-Edge-Yard` is sent), `yard` the yard's own name,
/// `user` whom the device calls as, `device` the device's name at the
/// yard, `token` the device token.
struct PairedYard: Equatable, Sendable {
    var name: String
    var yard: String
    var user: String
    var device: String
    var token: String

    /// What the head line calls it: its name at the edge, else its own.
    var title: String { name.isEmpty ? yard : name }
}

extension PairedYard: CustomStringConvertible {
    var description: String {
        "PairedYard(name=\(name), yard=\(yard), user=\(user), device=\(device), token=<token>)"
    }
}

/// What the records hold, read whole.
struct Kept: Equatable, Sendable {
    var account: Account? = nil
    var yards: [PairedYard] = []
    /// The selected yard's `PairedYard.name`; a paired yard's whenever
    /// any is paired, nil when none is.
    var selected: String? = nil

    var selectedYard: PairedYard? { yards.first { $0.name == selected } }
}

extension Kept: CustomStringConvertible {
    var description: String {
        let accountText = account.map { "\($0.account)@\($0.origin)" } ?? "none"
        let yardText = yards.map { $0.name.isEmpty ? $0.yard : $0.name }.joined(separator: ",")
        return "Kept(account=\(accountText), yards=[\(yardText)], selected=\(selected ?? "none"))"
    }
}

/// The records on `secret` and `plain`, for the edge at `origin`.
/// Read once when made: an account record of another edge sets every
/// record aside (3.2), and a record whose token is gone from the
/// Keychain is set aside alone. `kept` is what they hold from then on.
@MainActor
@Observable
final class Records {
    private(set) var kept: Kept

    private let secret: any Shelf
    private let plain: any Shelf
    private let origin: String
    private var observers: [UUID: @MainActor (Kept) -> Void] = [:]

    /// The last account name stored for this edge, also available when
    /// the session token is missing and the person must sign in again.
    var accountNameForSignIn: String? { plain.get(Self.accountNameKey) }

    init(secret: any Shelf, plain: any Shelf, origin: String) {
        self.secret = secret
        self.plain = plain
        self.origin = origin
        self.kept = Kept()
        self.kept = read()
    }

    static func live(origin: String) -> Records {
        Records(secret: KeychainShelf(), plain: UserDefaultsShelf(), origin: origin)
    }

    func observe(_ observer: @escaping @MainActor (Kept) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func publish() {
        for observer in observers.values { observer(kept) }
    }

    /// Keeps the session of a sign-in, in place of any before it.
    func keepSession(account: String, session: String) {
        secret.write(put: [Self.accountKey: session])
        plain.write(put: [Self.originKey: origin, Self.accountNameKey: account])
        kept.account = Account(origin: origin, account: account, session: session)
        publish()
    }

    /// Keeps a paired yard, in place of one of the same name, and selects it.
    func keepYard(_ yard: PairedYard) {
        secret.write(put: [Self.yardPrefix + yard.name: yard.token])
        let meta = StoredYard(name: yard.name, yard: yard.yard, user: yard.user, device: yard.device)
        let encoded = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        plain.write(put: [Self.yardMetaPrefix + yard.name: encoded, Self.selectedKey: yard.name])
        kept.yards = kept.yards.filter { $0.name != yard.name } + [yard]
        kept.selected = yard.name
        publish()
    }

    /// Selects the paired yard named `name`: the yard the app opens on.
    func select(_ name: String) {
        guard kept.yards.contains(where: { $0.name == name }) else { return }
        plain.write(put: [Self.selectedKey: name])
        kept.selected = name
        publish()
    }

    /// Deletes the record of the yard named `name`; another is
    /// selected where that one was.
    func forgetYard(_ name: String) {
        let yards = kept.yards.filter { $0.name != name }
        let selected = kept.selected.flatMap { s in yards.contains { $0.name == s } ? s : nil } ?? yards.first?.name
        secret.write(remove: [Self.yardPrefix + name])
        if let selected {
            plain.write(put: [Self.selectedKey: selected], remove: [Self.yardMetaPrefix + name])
        } else {
            plain.write(remove: [Self.yardMetaPrefix + name, Self.selectedKey])
        }
        kept.yards = yards
        kept.selected = selected
        publish()
    }

    /// Deletes every record: the phone holds no credential after.
    /// The notifications-asked flag stays: it was asked once.
    func forgetAll() {
        secret.write(remove: Array(secret.keys()))
        var plainRemove = [Self.originKey, Self.accountNameKey, Self.selectedKey]
        plainRemove += plain.keys().filter { $0.hasPrefix(Self.yardMetaPrefix) }
        plain.write(remove: plainRemove)
        kept = Kept()
        publish()
    }

    /// Whether the notifications permission was asked already: it is
    /// asked once, after the first pairing (3.2).
    var notificationsAsked: Bool { plain.get(Self.askedKey) != nil }

    func noteNotificationsAsked() {
        plain.write(put: [Self.askedKey: "yes"])
    }

    private func read() -> Kept {
        let storedOrigin = plain.get(Self.originKey)
        if let storedOrigin, storedOrigin != origin {
            secret.write(remove: Array(secret.keys()))
            let recordKeys = plain.keys().filter {
                $0 == Self.originKey || $0 == Self.accountNameKey || $0 == Self.selectedKey
                    || $0.hasPrefix(Self.yardMetaPrefix)
            }
            plain.write(remove: Array(recordKeys))
            return Kept()
        }
        var asideSecret: [String] = []
        var asidePlain: [String] = []
        var account: Account? = nil
        let accountName = plain.get(Self.accountNameKey)
        let session = secret.get(Self.accountKey)
        if accountName != nil || session != nil || storedOrigin != nil {
            if let accountName, !accountName.isEmpty, storedOrigin == origin {
                if let session, isToken(session) {
                    account = Account(origin: origin, account: accountName, session: session)
                } else if session != nil {
                    // Keep the account name so sign-in again can still
                    // ask for only its password.
                    asideSecret.append(Self.accountKey)
                }
            } else {
                if session != nil { asideSecret.append(Self.accountKey) }
                if accountName != nil { asidePlain.append(Self.accountNameKey) }
                if storedOrigin != nil { asidePlain.append(Self.originKey) }
            }
        }
        var yards: [PairedYard] = []
        for key in plain.keys().filter({ $0.hasPrefix(Self.yardMetaPrefix) }).sorted() {
            let name = String(key.dropFirst(Self.yardMetaPrefix.count))
            let secretKey = Self.yardPrefix + name
            guard let json = plain.get(key),
                  let meta = try? JSONDecoder().decode(StoredYard.self, from: Data(json.utf8)),
                  meta.name == name,
                  let token = secret.get(secretKey)
            else {
                asidePlain.append(key)
                if secret.get(secretKey) != nil { asideSecret.append(secretKey) }
                continue
            }
            yards.append(PairedYard(name: meta.name, yard: meta.yard, user: meta.user, device: meta.device, token: token))
        }
        if !asideSecret.isEmpty { secret.write(remove: asideSecret) }
        if !asidePlain.isEmpty { plain.write(remove: asidePlain) }
        let selected = plain.get(Self.selectedKey).flatMap { s in yards.contains { $0.name == s } ? s : nil }
            ?? yards.first?.name
        return Kept(account: account, yards: yards, selected: selected)
    }

    private struct StoredYard: Codable {
        var name: String
        var yard: String
        var user: String
        var device: String
    }

    private static let accountKey = "account"
    private static let yardPrefix = "yard:"
    private static let originKey = "origin"
    private static let accountNameKey = "account"
    private static let selectedKey = "selected"
    private static let askedKey = "notifications-asked"
    private static let yardMetaPrefix = "yard-meta:"
}
