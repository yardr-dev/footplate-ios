import Foundation
import Security

// The records of design 3.2: one for the account and its session, one
// per paired yard and its device token, and the selected yard's name.
// Both tokens live in the Keychain (ThisDeviceOnly, never
// synchronised); the origin, the names, the account with its handle
// and the selection are not secret and live on the plain shelf.

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
/// account value per record, ThisDeviceOnly and never synchronised,
/// so no token reaches iCloud Keychain, a backup or another device.
/// With an access group (the live shelf, design 8787 section 4) the
/// items stand in the group the notification service extension
/// shares, at `AfterFirstUnlockThisDeviceOnly`, so it can fetch
/// while the screen is locked after the first unlock; without one
/// they stand as they always did, `WhenUnlockedThisDeviceOnly`. An
/// item kept before the group is read where it lies and moved into
/// the group at its next write, so an upgraded phone keeps its
/// pairing.
final class KeychainShelf: Shelf, @unchecked Sendable {
    static let service = "dev.yardr.footplate"

    /// The group the items stand in, as the entitlement names it
    /// without its App ID prefix; the prefix is the system's, so the
    /// name it stands under is read back from a probe item (below)
    /// rather than written here in a form one build may expand
    /// otherwise.
    private let accessGroup: String?
    private let probeLock = NSLock()
    private var probedGroup: String??

    init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    /// The access group as the system expanded it, or nil where
    /// this shelf stands ungrouped. An item added with no group
    /// lands in the first of the entitlement's groups, expanded:
    /// its read-back names the group every grouped query must use.
    private var group: String? {
        guard let accessGroup else { return nil }
        probeLock.lock()
        defer { probeLock.unlock() }
        if let probedGroup { return probedGroup }
        let resolved = probeGroup() ?? accessGroup
        probedGroup = resolved
        return resolved
    }

    private func probeGroup() -> String? {
        let probeKey = "access-group-probe"
        var add = baseQuery(probeKey, grouped: false)
        add[kSecValueData as String] = Data("x".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        SecItemAdd(add as CFDictionary, nil)
        var query = baseQuery(probeKey, grouped: false)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        var found: String?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let attributes = item as? [String: Any] {
            found = attributes[kSecAttrAccessGroup as String] as? String
        }
        SecItemDelete(baseQuery(probeKey, grouped: false) as CFDictionary)
        return found
    }

    private func baseQuery(_ key: String, grouped: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        if grouped, let group {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    func get(_ key: String) -> String? {
        if accessGroup != nil, let grouped = read(key, grouped: true) {
            return grouped
        }
        return read(key, grouped: false)
    }

    private func read(_ key: String, grouped: Bool) -> String? {
        var query = baseQuery(key, grouped: grouped)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func keys() -> Set<String> {
        var all = accounts(grouped: false)
        if accessGroup != nil {
            all.formUnion(accounts(grouped: true))
        }
        return all
    }

    private func accounts(grouped: Bool) -> Set<String> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if grouped, let group {
            query[kSecAttrAccessGroup as String] = group
        }
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    func write(put: [String: String], remove: [String]) {
        for key in remove {
            SecItemDelete(baseQuery(key, grouped: true) as CFDictionary)
            SecItemDelete(baseQuery(key, grouped: false) as CFDictionary)
        }
        for (key, value) in put {
            let data = Data(value.utf8)
            if accessGroup != nil {
                // Its ungrouped copy of before the group goes first:
                // deleted after, it would take the grouped item with
                // it where the group is the default one.
                SecItemDelete(baseQuery(key, grouped: false) as CFDictionary)
            }
            var query = baseQuery(key, grouped: accessGroup != nil)
            query[kSecAttrSynchronizable as String] = false
            let update: [String: Any] = [kSecValueData as String: data]
            if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = accessGroup != nil
                    ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                add[kSecAttrSynchronizable as String] = false
                SecItemAdd(add as CFDictionary, nil)
            }
        }
    }
}

/// The namespace of the records' plain-shelf keys, in whichever
/// defaults they lie: the standard ones before the app group, and
/// the group's suite since (below), so `Records.live` can carry the
/// one set over to the other.
let recordsDefaultsPrefix = "dev.yardr.footplate.records."

/// `UserDefaults` as the plain shelf, its keys namespaced so the
/// records' keys are the only ones this shelf names.
final class UserDefaultsShelf: Shelf, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = recordsDefaultsPrefix

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
/// in at, `account` the email or handle it signed in as, `handle` the
/// name the edge gives the account's own yard (empty for a session
/// kept before the handle was, until it is read from whoami or sign-in),
/// `session` the token Kratos answered.
struct Account: Equatable, Sendable {
    var origin: String
    var account: String
    var handle: String
    var session: String
}

extension Account: CustomStringConvertible {
    var description: String { "Account(\(origin), \(account), session=<token>)" }
}

/// One paired yard: `name` its name at the edge (empty: the account's
/// own, and no `X-Edge-Yard` is sent), `yard` the yard's own name,
/// `user` whom the device calls as, `device` the device's name at the
/// yard, `token` the device token, `origin` the yard's own address,
/// empty for the edge's. A yard of its own has no name at any edge, so
/// the records call it by the name its address gives it (`ownName`),
/// which no request carries. A yard of another account, one the account
/// is a member of, is named `owner/yard` at the edge, which every
/// request carries as it is (`memberYard`).
struct PairedYard: Equatable, Sendable {
    var name: String
    var yard: String
    var user: String
    var device: String
    var token: String
    var origin: String = ""

    /// The handle of the account the yard belongs to, where it is
    /// another's; empty for the account's own yard and a yard of its
    /// own, whose names hold no slash.
    var owner: String { memberYard(name)?.owner ?? "" }

    /// What the head line calls it: its name at the edge, else its own.
    /// A yard of another account says so beside its name, so a member
    /// never takes it for one of their own.
    var title: String {
        if let member = memberYard(name) { return "\(member.yard) — member of \(member.owner)'s yard" }
        return name.isEmpty ? yard : name
    }
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

    /// The name `nameYardOfItsOwn` moved a yard of its own to when
    /// these records were read, if it moved one this launch: the app
    /// clears the delivered notifications the yard left under its old
    /// name `""` where this is set. Nil where nothing moved — no `""`
    /// record, an edge-owned `""` yard, or a refused move.
    private(set) var migratedYardName: String? = nil

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

    /// The records as the app and its extension keep them: the
    /// secrets in the shared Keychain group (Push.swift), and the
    /// plain shelf in the app group's suite, where the extension
    /// reads the yards' names beside the checkpoints. What a phone
    /// kept in the standard defaults before the group is carried
    /// over once, where the suite holds none of it yet.
    static func live(origin: String) -> Records {
        let plain: any Shelf
        if let suite = UserDefaults(suiteName: pushAppGroup) {
            for (key, value) in UserDefaults.standard.dictionaryRepresentation()
            where key.hasPrefix(recordsDefaultsPrefix) && suite.object(forKey: key) == nil {
                suite.set(value, forKey: key)
            }
            plain = UserDefaultsShelf(defaults: suite)
        } else {
            plain = UserDefaultsShelf()
        }
        return Records(secret: KeychainShelf(accessGroup: pushKeychainGroup), plain: plain, origin: origin)
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

    /// Keeps the session of a sign-in, in place of any before it. The
    /// handle of an earlier sign-in is not kept beside another's.
    func keepSession(account: String, handle: String = "", session: String) {
        secret.write(put: [Self.accountKey: session])
        var put = [Self.originKey: origin, Self.accountNameKey: account]
        if !handle.isEmpty { put[Self.accountHandleKey] = handle }
        plain.write(put: put, remove: handle.isEmpty ? [Self.accountHandleKey] : [])
        kept.account = Account(origin: origin, account: account, handle: handle, session: session)
        publish()
    }

    /// Adds the handle resolved for an existing session, but only while
    /// that same session is still the account kept here.
    func keepAccountHandle(_ handle: String, for session: String) {
        guard !handle.isEmpty,
              var account = kept.account,
              account.session == session,
              account.handle.isEmpty
        else { return }
        plain.write(put: [Self.accountHandleKey: handle])
        account.handle = handle
        kept.account = account
        publish()
    }

    /// Keeps a paired yard, in place of one of the same name, and selects it.
    func keepYard(_ yard: PairedYard) {
        secret.write(put: [Self.yardPrefix + yard.name: yardSecret(token: yard.token, origin: yard.origin)])
        let meta = StoredYard(name: yard.name, yard: yard.yard, user: yard.user, device: yard.device)
        plain.write(put: [Self.yardMetaPrefix + yard.name: encoded(meta), Self.selectedKey: yard.name])
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
        var plainRemove = [Self.originKey, Self.accountNameKey, Self.accountHandleKey, Self.selectedKey]
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
                $0 == Self.originKey || $0 == Self.accountNameKey || $0 == Self.accountHandleKey
                    || $0 == Self.selectedKey || $0.hasPrefix(Self.yardMetaPrefix)
            }
            plain.write(remove: Array(recordKeys))
            return Kept()
        }
        migratedYardName = nameYardOfItsOwn()
        var asideSecret: [String] = []
        var asidePlain: [String] = []
        var account: Account? = nil
        let accountName = plain.get(Self.accountNameKey)
        let session = secret.get(Self.accountKey)
        if accountName != nil || session != nil || storedOrigin != nil {
            if let accountName, !accountName.isEmpty, storedOrigin == origin {
                if let session, isToken(session) {
                    account = Account(
                        origin: origin, account: accountName,
                        handle: plain.get(Self.accountHandleKey) ?? "", session: session
                    )
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
                  let stored = secret.get(secretKey)
            else {
                asidePlain.append(key)
                if secret.get(secretKey) != nil { asideSecret.append(secretKey) }
                continue
            }
            let (token, origin) = readYardSecret(stored)
            yards.append(PairedYard(name: meta.name, yard: meta.yard, user: meta.user, device: meta.device, token: token, origin: origin))
        }
        if !asideSecret.isEmpty { secret.write(remove: asideSecret) }
        if !asidePlain.isEmpty { plain.write(remove: asidePlain) }
        let selected = plain.get(Self.selectedKey).flatMap { s in yards.contains { $0.name == s } ? s : nil }
            ?? yards.first?.name
        return Kept(account: account, yards: yards, selected: selected)
    }

    /// A yard of its own was kept under the name "" before its address
    /// named it, which is the account's own yard's name: moved to its
    /// address's name once, so a phone that paired one keeps it, and
    /// follows it, beside the edge's own. The new secret goes first and
    /// is read back before anything else moves, then the plain shelf
    /// changes in one write (the new meta, the old one gone, the
    /// selection with it), and the old secret goes last: a restart in
    /// between finds a record that reads, and moves the rest. Left as it
    /// is where the name is held by another record already. Answers
    /// the name it moved the record to, or nil where nothing moved.
    private func nameYardOfItsOwn() -> String? {
        guard let json = plain.get(Self.yardMetaPrefix),
              var meta = try? JSONDecoder().decode(StoredYard.self, from: Data(json.utf8)),
              meta.name.isEmpty,
              let stored = secret.get(Self.yardPrefix)
        else { return nil }
        // No origin, no name: the account's own yard stays "".
        let name = ownName(readYardSecret(stored).origin)
        let metaKey = Self.yardMetaPrefix + name
        let secretKey = Self.yardPrefix + name
        guard !name.isEmpty, plain.get(metaKey) == nil, secret.get(secretKey).map({ $0 == stored }) ?? true else { return nil }
        secret.write(put: [secretKey: stored])
        guard secret.get(secretKey) == stored else { return nil }
        meta.name = name
        var put = [metaKey: encoded(meta)]
        if plain.get(Self.selectedKey) == "" { put[Self.selectedKey] = name }
        plain.write(put: put, remove: [Self.yardMetaPrefix])
        secret.write(remove: [Self.yardPrefix])
        return name
    }

    private func encoded(_ meta: StoredYard) -> String {
        (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
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
    private static let accountHandleKey = "account-handle"
    private static let selectedKey = "selected"
    private static let askedKey = "notifications-asked"
    private static let yardMetaPrefix = "yard-meta:"
}

/// The mark a yard of its own leaves on its Keychain record: a bare
/// token is one line with no spaces (`isToken`), so the mark's space
/// keeps the two forms apart whatever a yard answers as its token.
private let directSecretMark = "direct "

/// The value a yard's Keychain record holds for `token` with `origin`
/// beside it: the token alone where the yard is the edge's, so
/// records written before a yard of its own could be paired read as
/// they always did.
private func yardSecret(token: String, origin: String) -> String {
    guard !origin.isEmpty else { return token }
    struct Secret: Codable {
        var token: String
        var origin: String
    }
    guard let json = (try? JSONEncoder().encode(Secret(token: token, origin: origin)))
        .flatMap({ String(data: $0, encoding: .utf8) })
    else { return token }
    return directSecretMark + json
}

/// A yard's Keychain record read: the token with its origin where the
/// mark is, or the bare token of a record written before, whose yard
/// is the edge's. A marked record that cannot be read is the bare
/// token whole, whose space keeps it out of any request.
private func readYardSecret(_ stored: String) -> (token: String, origin: String) {
    struct Secret: Codable {
        var token: String
        var origin: String
    }
    if stored.hasPrefix(directSecretMark),
       let data = String(stored.dropFirst(directSecretMark.count)).data(using: .utf8),
       let secret = try? JSONDecoder().decode(Secret.self, from: data),
       !secret.origin.isEmpty
    {
        return (secret.token, secret.origin)
    }
    return (stored, "")
}
