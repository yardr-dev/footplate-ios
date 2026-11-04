@testable import Footplate
import XCTest

// The records of design 3.2 on memory shelves: the tokens on the
// secret shelf alone, read back by a new Records as a restart
// would, set aside where their token is gone, and every record set
// aside for another edge. The push token the registrar keeps beside
// them stands where every record is forgotten. The Keychain itself
// is the device check named in the bead's note.
@MainActor
final class RecordsTests: XCTestCase {
    private let edge = "https://my.yardr.dev"

    private func makeRecords(
        secret: MemoryShelf, plain: MemoryShelf, origin: String? = nil
    ) -> Records {
        Records(secret: secret, plain: plain, origin: origin ?? edge)
    }

    /// How often the records told their observers of a change.
    @MainActor
    private final class Published {
        var count = 0
    }

    func testTheTokensAreKeptAndReadBackAfterARestart() {
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = makeRecords(secret: secret, plain: plain)
        records.keepSession(account: "mckean@example.com", session: "ory_st_secret")
        records.keepAccountHandle("wrong", for: "ory_st_other")
        XCTAssertEqual(records.kept.account?.handle, "")
        records.keepAccountHandle("mckean", for: "ory_st_secret")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-1"))
        records.keepYard(PairedYard(name: "", yard: "south", user: "mckean", device: "pixel", token: "yardr-dev-south-1"))
        // Neither token lies on the plain shelf in the clear.
        let plainText = plain.map.values.joined()
        XCTAssertFalse(plainText.contains("ory_st_secret"), plainText)
        XCTAssertFalse(plainText.contains("yardr-dev-"), plainText)
        // The selection and the account's handle are names on the plain shelf.
        XCTAssertEqual(plain.map["selected"], "")
        XCTAssertEqual(plain.map["account-handle"], "mckean")

        let again = makeRecords(secret: secret, plain: plain).kept
        XCTAssertEqual(again.account?.session, "ory_st_secret")
        XCTAssertEqual(again.account?.account, "mckean@example.com")
        XCTAssertEqual(again.account?.handle, "mckean")
        XCTAssertEqual(again.yards.map(\.name), ["", "laptop"])
        XCTAssertEqual(again.yards.map(\.token), ["yardr-dev-south-1", "yardr-dev-laptop-1"])
        XCTAssertEqual(again.selected, "")
        XCTAssertEqual(again.selectedYard.map { "\($0.title) · \($0.user)" }, "south · mckean")
        // Nothing that holds a token prints it.
        let described = String(describing: again)
        XCTAssertFalse(described.contains("ory_st"), described)
        XCTAssertFalse(described.contains("yardr-dev"), described)

        // The next sign-in keeps its own handle, and one that answers
        // none leaves no handle of the account before it.
        records.keepSession(account: "jo@example.com", handle: "jo", session: "ory_st_next")
        XCTAssertEqual(makeRecords(secret: secret, plain: plain).kept.account?.handle, "jo")
        records.keepSession(account: "no@example.com", session: "ory_st_last")
        XCTAssertEqual(records.kept.account?.handle, "")
        XCTAssertNil(plain.map["account-handle"])
        XCTAssertEqual(makeRecords(secret: secret, plain: plain).kept.account?.handle, "")

        // A yard of another account is kept under the name the edge
        // gives it, its owner's handle and its own, which says whose it
        // is: the head line calls it so, and the own yards are as before.
        XCTAssertEqual(again.yards.map(\.owner), ["", ""])
        records.keepYard(PairedYard(name: "alice/lab", yard: "lab", user: "joe", device: "phone", token: "yardr-dev-lab-1"))
        XCTAssertEqual(secret.map["yard:alice/lab"], "yardr-dev-lab-1")
        let member = makeRecords(secret: secret, plain: plain).kept.yards.first { $0.name == "alice/lab" }
        XCTAssertEqual(member?.token, "yardr-dev-lab-1")
        XCTAssertEqual(member?.owner, "alice")
        XCTAssertEqual(member?.title, "lab — member of alice's yard")
        XCTAssertEqual(makeRecords(secret: secret, plain: plain).kept.selected, "alice/lab")

        // A name the person gives a yard on this phone lies with the yard's
        // record on the plain shelf and nowhere else, trimmed, and is read
        // back after a restart; `name` and `yard`, which requests carry, are
        // as they were. A record kept before the field reads as it always
        // did, and a yard never named is written without it.
        let unnamed = plain.map["yard-meta:laptop"] ?? ""
        XCTAssertFalse(unnamed.contains("localName"), unnamed)
        plain.write(put: ["yard-meta:laptop": #"{"name":"laptop","yard":"laptop","user":"mckean","device":"pixel"}"#])
        let old = makeRecords(secret: secret, plain: plain).kept.yards.first { $0.name == "laptop" }
        XCTAssertNil(old?.localName)
        XCTAssertEqual(old?.title, "laptop")
        let published = Published()
        _ = records.observe { _ in published.count += 1 }
        records.renameYard("laptop", to: "  Back shed\n")
        records.renameYard("alice/lab", to: "Bench")
        records.renameYard("nowhere", to: "Ghost")
        XCTAssertEqual(published.count, 0, "what follows and registers yards reads their names at the edge, which a name of the person's own leaves be")
        XCTAssertFalse(secret.map.values.joined().contains("Back shed"), "\(secret.map)")
        let named = Dictionary(uniqueKeysWithValues: makeRecords(secret: secret, plain: plain).kept.yards.map { ($0.name, $0) })
        XCTAssertEqual(named.keys.sorted(), ["", "alice/lab", "laptop"])
        XCTAssertEqual(named["laptop"]?.title, "Back shed")
        XCTAssertEqual(named["laptop"].map { "\($0.name) · \($0.yard)" }, "laptop · laptop")
        XCTAssertEqual(named["alice/lab"]?.title, "Bench — member of alice's yard")
        XCTAssertEqual(named["alice/lab"].map { "\($0.name) · \($0.yard)" }, "alice/lab · lab")
        XCTAssertEqual(named[""]?.title, "south")

        // Clearing it, with nothing or only space, brings the old name back.
        records.renameYard("laptop", to: " ")
        records.renameYard("alice/lab", to: "")
        let cleared = makeRecords(secret: secret, plain: plain).kept
        XCTAssertEqual(cleared.yards.map(\.title).sorted(), ["lab — member of alice's yard", "laptop", "south"])
        XCTAssertFalse((plain.map["yard-meta:laptop"] ?? "").contains("localName"), "\(plain.map)")

        // Pairing the same yard again keeps the name, and forgetting the
        // yard takes it with the rest of its record.
        records.renameYard("laptop", to: "Back shed")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-2"))
        XCTAssertEqual(published.count, 1, "a pairing is told, so the silence above is the rename's")
        XCTAssertEqual(records.kept.yards.first { $0.name == "laptop" }?.localName, "Back shed")
        XCTAssertEqual(makeRecords(secret: secret, plain: plain).kept.yards.first { $0.name == "laptop" }?.title, "Back shed")
        records.forgetYard("laptop")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-3"))
        XCTAssertNil(records.kept.yards.first { $0.name == "laptop" }?.localName)
    }

    func testAYardOfItsOwnKeepsItsAddressWithItsToken() {
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = makeRecords(secret: secret, plain: plain)
        records.keepYard(PairedYard(name: "yard.example.net", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-9", origin: "https://yard.example.net"))
        // The address lies beside the token on the secret shelf, never
        // on the plain one: the plain shelf holds the yard's name, its
        // host, and no request goes to a name.
        let stored = secret.map["yard:yard.example.net"] ?? ""
        XCTAssertTrue(stored.contains("yardr-dev-south-9"), stored)
        XCTAssertTrue(stored.contains("yard.example.net"), stored)
        let plainText = plain.map.values.joined()
        XCTAssertFalse(plainText.contains("https:"), plainText)
        XCTAssertFalse(plainText.contains("yardr-dev-"), plainText)
        // The app reopens on the kept address.
        let again = makeRecords(secret: secret, plain: plain).kept
        XCTAssertEqual(again.yards.map(\.name), ["yard.example.net"])
        XCTAssertEqual(again.yards.map(\.origin), ["https://yard.example.net"])
        XCTAssertEqual(again.yards.map(\.token), ["yardr-dev-south-9"])
        XCTAssertEqual(again.selected, "yard.example.net")
        // A record written before, the bare token alone, reads as the
        // edge's yard.
        secret.write(put: ["yard:yard.example.net": "yardr-dev-south-1"])
        let legacy = makeRecords(secret: secret, plain: plain).kept
        XCTAssertEqual(legacy.yards.map(\.origin), [""])
        XCTAssertEqual(legacy.yards.map(\.token), ["yardr-dev-south-1"])
        // Forgetting deletes the address with the token.
        records.forgetYard("yard.example.net")
        XCTAssertNil(secret.map["yard:yard.example.net"])
        XCTAssertTrue(records.kept.yards.isEmpty)
        XCTAssertTrue(makeRecords(secret: secret, plain: plain).kept.yards.isEmpty)
    }

    func testAYardOfItsOwnKeptNamelessIsNamedByItsAddressOnce() {
        let name = "workshop-mini.tail1a2b3c.ts.net:8446"
        let origin = "https://workshop-mini.tail1a2b3c.ts.net:8446"
        // Kept as a phone kept it before an address named a yard: under
        // "", which is the account's own yard's name, and selected or
        // not.
        for selecting in ["", "laptop"] {
            let secret = MemoryShelf()
            let plain = MemoryShelf()
            let records = makeRecords(secret: secret, plain: plain)
            records.keepSession(account: "mckean@example.com", handle: "mckean", session: "ory_st_secret")
            records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-1"))
            records.keepYard(PairedYard(name: "", yard: "plantime", user: "mckean", device: "phone", token: "yardr-dev-plantime-1", origin: origin))
            records.select(selecting)

            // Renamed on load, with its token, address and the rest of
            // its record; the selection follows it where it was on it,
            // and the move is reported for this launch.
            let reread = makeRecords(secret: secret, plain: plain)
            XCTAssertEqual(name, reread.migratedYardName)
            let moved = reread.kept
            XCTAssertEqual(moved.yards.map(\.name), ["laptop", name])
            let plantime = moved.yards.first { $0.name == name }
            XCTAssertEqual(plantime?.token, "yardr-dev-plantime-1")
            XCTAssertEqual(plantime?.origin, origin)
            XCTAssertEqual(plantime.map { "\($0.title) · \($0.yard) · \($0.user) · \($0.device)" }, "\(name) · plantime · mckean · phone")
            XCTAssertEqual(moved.selected, selecting.isEmpty ? name : "laptop")
            XCTAssertEqual(plain.map["selected"], moved.selected)
            // The old keys are gone, and no token reached the plain shelf.
            XCTAssertNil(secret.map["yard:"])
            XCTAssertNil(plain.map["yard-meta:"])
            XCTAssertFalse(plain.map.values.joined().contains("yardr-dev-"), "\(plain.map)")

            // Once: another start moves nothing, and reports nothing.
            let secretAfter = secret.map
            let plainAfter = plain.map
            let again = makeRecords(secret: secret, plain: plain)
            XCTAssertEqual(again.kept, moved)
            XCTAssertNil(again.migratedYardName)
            XCTAssertEqual(secret.map, secretAfter)
            XCTAssertEqual(plain.map, plainAfter)

            // The account's own yard is paired beside it, as it could
            // not be while the two shared a name.
            records.keepYard(PairedYard(name: "", yard: "south", user: "mckean", device: "phone", token: "yardr-dev-south-1"))
            let beside = makeRecords(secret: secret, plain: plain).kept
            XCTAssertEqual(beside.yards.map(\.name), ["", "laptop", name])
            XCTAssertEqual(beside.yards.map(\.origin), ["", "", origin])
        }

        // A move a restart cut short, the new secret written and the
        // rest not, is finished by the next start.
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = makeRecords(secret: secret, plain: plain)
        records.keepYard(PairedYard(name: "", yard: "plantime", user: "mckean", device: "phone", token: "yardr-dev-plantime-1", origin: origin))
        secret.write(put: ["yard:" + name: secret.map["yard:"] ?? ""])
        let resumed = makeRecords(secret: secret, plain: plain)
        XCTAssertEqual(name, resumed.migratedYardName)
        let finished = resumed.kept
        XCTAssertEqual(finished.yards.map(\.name), [name])
        XCTAssertEqual(finished.selected, name)
        XCTAssertNil(secret.map["yard:"])
        XCTAssertNil(plain.map["yard-meta:"])

        // The edge's own yard has no address to name it by: it stays "",
        // and no migration is reported.
        let ownSecret = MemoryShelf()
        let ownPlain = MemoryShelf()
        let own = makeRecords(secret: ownSecret, plain: ownPlain)
        own.keepYard(PairedYard(name: "", yard: "south", user: "mckean", device: "phone", token: "yardr-dev-south-1"))
        XCTAssertEqual(own.kept.yards.map(\.name), [""])
        let ownAgain = makeRecords(secret: ownSecret, plain: ownPlain)
        XCTAssertEqual(ownAgain.kept.yards.map(\.name), [""])
        XCTAssertNil(ownAgain.migratedYardName)

        // A name an edge yard holds already is not taken twice: the
        // record stays as it was, and no migration is reported.
        let heldSecret = MemoryShelf()
        let heldPlain = MemoryShelf()
        let held = makeRecords(secret: heldSecret, plain: heldPlain)
        held.keepYard(PairedYard(name: "yard.example.net", yard: "laptop", user: "jo", device: "pixel", token: "yardr-dev-laptop-1"))
        held.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1", origin: "https://yard.example.net"))
        let refused = makeRecords(secret: heldSecret, plain: heldPlain)
        XCTAssertNil(refused.migratedYardName)
        let both = refused.kept
        XCTAssertEqual(both.yards.map(\.name), ["", "yard.example.net"])
        XCTAssertEqual(both.yards.map(\.origin), ["https://yard.example.net", ""])
    }

    func testATokenShapedLikeAKeychainSecretReadsAsTheEdgesYard() {
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = makeRecords(secret: secret, plain: plain)
        // A yard's token is one line of visible characters, which a
        // `{"token":...,"origin":...}` line is: kept bare for an edge
        // yard, it reads back whole, never as a yard of its own at
        // the origin it names.
        let shaped = #"{"token":"abc","origin":"https://collector.example"}"#
        XCTAssertTrue(isToken(shaped))
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: shaped))
        let again = makeRecords(secret: secret, plain: plain).kept
        XCTAssertEqual(again.yards.map(\.token), [shaped])
        XCTAssertEqual(again.yards.map(\.origin), [""])
    }

    func testARecordWhoseTokenIsGoneIsSetAside() {
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        makeRecords(secret: secret, plain: plain).keepSession(account: "mckean@example.com", session: "ory_st_secret")
        let records = makeRecords(secret: secret, plain: plain)
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-1"))
        records.keepYard(PairedYard(name: "", yard: "south", user: "mckean", device: "pixel", token: "yardr-dev-south-1"))
        // The home yard's token is gone, as a lost Keychain item is.
        secret.write(remove: ["yard:"])
        let kept = makeRecords(secret: secret, plain: plain).kept
        XCTAssertEqual(kept.yards.map(\.name), ["laptop"])
        XCTAssertNil(plain.map["yard-meta:"])

        // If the account's session item is gone, keep its non-secret
        // identity so sign-in again can still ask for only the password.
        secret.write(remove: ["account"])
        let withoutSession = makeRecords(secret: secret, plain: plain)
        XCTAssertNil(withoutSession.kept.account)
        XCTAssertEqual(withoutSession.accountNameForSignIn, "mckean@example.com")
        XCTAssertEqual(withoutSession.kept.yards.map(\.name), ["laptop"])

        // Every token gone: nothing opens.
        secret.write(remove: Array(secret.keys()))
        let keyless = makeRecords(secret: secret, plain: plain).kept
        XCTAssertNil(keyless.account)
        XCTAssertTrue(keyless.yards.isEmpty)
    }

    func testRecordsOfAnotherEdgeAreSetAside() {
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = makeRecords(secret: secret, plain: plain)
        records.keepSession(account: "mckean@example.com", handle: "mckean", session: "ory_st_secret")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-1"))
        let kept = makeRecords(secret: secret, plain: plain, origin: "https://test.yardr.dev").kept
        XCTAssertEqual(kept, Kept())
        XCTAssertTrue(secret.map.isEmpty, "\(secret.map)")
        XCTAssertTrue(plain.map.isEmpty, "\(plain.map)")
    }

    func testForgettingMovesTheSelectionAndTheLastLeavesNoCredential() {
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = makeRecords(secret: secret, plain: plain)
        records.keepSession(account: "mckean@example.com", handle: "mckean", session: "ory_st_secret")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-1"))
        records.keepYard(PairedYard(name: "", yard: "south", user: "mckean", device: "pixel", token: "yardr-dev-south-1"))
        // The notifications permission is asked once: the flag is
        // kept even when every credential is forgotten.
        XCTAssertFalse(records.notificationsAsked)
        records.noteNotificationsAsked()
        XCTAssertTrue(records.notificationsAsked)
        // The push token the registrar keeps on the secret shelf is a
        // delivery address, no credential: it stands too, since the
        // system hands it over again only at a launch.
        secret.write(put: [pushTokenKey: "apns-token-1"])
        records.select("laptop")
        records.forgetYard("laptop")
        XCTAssertEqual(records.kept.selected, "")
        XCTAssertEqual(makeRecords(secret: secret, plain: plain).kept.selected, "")
        records.forgetAll()
        XCTAssertEqual(records.kept, Kept())
        XCTAssertEqual(secret.map, [pushTokenKey: "apns-token-1"], "the session and the yard's token are gone, the push token is not")
        XCTAssertTrue(records.notificationsAsked)
        let recordKeys = plain.map.keys.filter {
            $0 == "origin" || $0 == "account" || $0 == "account-handle" || $0 == "selected" || $0.hasPrefix("yard-meta:")
        }
        XCTAssertTrue(recordKeys.isEmpty, "\(plain.map)")
    }

    func testAYardPairedAfterTheLastWasForgottenIsRegisteredWithoutALaunch() async throws {
        // The records and the registrar on one shelf, as the app has
        // them on the one Keychain, over the fake edge.
        let fake = FakeYard()
        let shelf = MemoryShelf()
        let records = makeRecords(secret: shelf, plain: MemoryShelf(), origin: fake.origin)
        let registrar = PushRegistrar(edge: try fake.edge(), records: records, secret: shelf)
        func registers() -> [RecordedRequest] {
            fake.allRequests.filter { $0.path == "/user/push/register" }
        }
        records.keepSession(account: fake.email, session: fake.session())
        let laptop = PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: fake.token(yardName: "laptop"))
        records.keepYard(laptop)
        await registrar.tokenReceived("apns-token-1")
        XCTAssertEqual(registers().count, 1)
        XCTAssertEqual(fake.pushToken(yardName: "laptop"), "apns-token-1")

        // The last yard forgotten as the pairer forgets it: its row
        // undone while its credentials stand, then every record
        // deleted. The relay holds no row for it, and the push token
        // is all the shelf holds.
        await registrar.unregister(yard: laptop)
        records.forgetAll()
        XCTAssertNil(fake.pushToken(yardName: "laptop"))
        XCTAssertEqual(registrar.token, "apns-token-1")
        XCTAssertEqual(shelf.map, [pushTokenKey: "apns-token-1"])

        // Signed in and paired again with no launch between, the system
        // gives no token: the yard is registered with the one that
        // stood, by one call as its new device.
        let session = fake.session()
        records.keepSession(account: fake.email, session: session)
        let again = PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: fake.token(yardName: "laptop"))
        records.keepYard(again)
        await registrar.yardsChanged()
        XCTAssertEqual(registers().count, 2, "one call since the first, for the yard paired again")
        let sent = try XCTUnwrap(registers().last)
        XCTAssertEqual(sent.method, "POST")
        assertHeaders(sent, token: again.token, yard: "laptop", session: session)
        assertBody(sent, #"{"platform":"apns","token":"apns-token-1"}"#)
        XCTAssertEqual(fake.pushToken(yardName: "laptop"), "apns-token-1")
    }
}
