@testable import Footplate
import XCTest

// The records of design 3.2 on memory shelves: the tokens on the
// secret shelf alone, read back by a new Records as a restart
// would, set aside where their token is gone, and every record set
// aside for another edge. The Keychain itself is the device check
// named in the bead's note.
@MainActor
final class RecordsTests: XCTestCase {
    private let edge = "https://my.yardr.dev"

    private func makeRecords(
        secret: MemoryShelf, plain: MemoryShelf, origin: String? = nil
    ) -> Records {
        Records(secret: secret, plain: plain, origin: origin ?? edge)
    }

    func testTheTokensAreKeptAndReadBackAfterARestart() {
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = makeRecords(secret: secret, plain: plain)
        records.keepSession(account: "mckean@example.com", session: "ory_st_secret")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-1"))
        records.keepYard(PairedYard(name: "", yard: "south", user: "mckean", device: "pixel", token: "yardr-dev-south-1"))
        // Neither token lies on the plain shelf in the clear.
        let plainText = plain.map.values.joined()
        XCTAssertFalse(plainText.contains("ory_st_secret"), plainText)
        XCTAssertFalse(plainText.contains("yardr-dev-"), plainText)
        // The selection is a name on the plain shelf.
        XCTAssertEqual(plain.map["selected"], "")

        let again = makeRecords(secret: secret, plain: plain).kept
        XCTAssertEqual(again.account?.session, "ory_st_secret")
        XCTAssertEqual(again.account?.account, "mckean@example.com")
        XCTAssertEqual(again.yards.map(\.name), ["", "laptop"])
        XCTAssertEqual(again.yards.map(\.token), ["yardr-dev-south-1", "yardr-dev-laptop-1"])
        XCTAssertEqual(again.selected, "")
        XCTAssertEqual(again.selectedYard.map { "\($0.title) · \($0.user)" }, "south · mckean")
        // Nothing that holds a token prints it.
        let described = String(describing: again)
        XCTAssertFalse(described.contains("ory_st"), described)
        XCTAssertFalse(described.contains("yardr-dev"), described)
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
        records.keepSession(account: "mckean@example.com", session: "ory_st_secret")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-1"))
        let kept = makeRecords(secret: secret, plain: plain, origin: "https://test.yardr.dev").kept
        XCTAssertEqual(kept, Kept())
        XCTAssertTrue(secret.map.isEmpty, "\(secret.map)")
        XCTAssertTrue(plain.map.isEmpty, "\(plain.map)")
    }

    func testForgettingMovesTheSelectionAndTheLastLeavesNothing() {
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = makeRecords(secret: secret, plain: plain)
        records.keepSession(account: "mckean@example.com", session: "ory_st_secret")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "mckean", device: "pixel", token: "yardr-dev-laptop-1"))
        records.keepYard(PairedYard(name: "", yard: "south", user: "mckean", device: "pixel", token: "yardr-dev-south-1"))
        // The notifications permission is asked once: the flag is
        // kept even when every credential is forgotten.
        XCTAssertFalse(records.notificationsAsked)
        records.noteNotificationsAsked()
        XCTAssertTrue(records.notificationsAsked)
        records.select("laptop")
        records.forgetYard("laptop")
        XCTAssertEqual(records.kept.selected, "")
        XCTAssertEqual(makeRecords(secret: secret, plain: plain).kept.selected, "")
        records.forgetAll()
        XCTAssertEqual(records.kept, Kept())
        XCTAssertTrue(secret.map.isEmpty, "\(secret.map)")
        let recordKeys = plain.map.keys.filter {
            $0 == "origin" || $0 == "account" || $0 == "selected" || $0.hasPrefix("yard-meta:")
        }
        XCTAssertTrue(recordKeys.isEmpty, "\(plain.map)")
    }
}
