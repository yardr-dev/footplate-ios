@testable import Footplate
import XCTest

// The shared Keychain group the extension reads its credentials
// from (design 8787 section 4), on the simulator's Keychain: an
// item written in the group by one shelf is read by another, as the
// extension reads what the app kept, and no item of the group's is
// an app-group file. The accessibility class itself —
// `AfterFirstUnlockThisDeviceOnly`, so a locked phone after its
// first unlock can fetch — is the device check named in the note.
final class KeychainGroupTests: XCTestCase {
    func testTheSharedGroupRoundTripsBetweenTwoShelves() {
        let key = "push-test-\(UUID().uuidString)"
        let app = KeychainShelf(accessGroup: pushKeychainGroup)
        let ext = KeychainShelf(accessGroup: pushKeychainGroup)
        app.write(put: [key: "yardr-dev-test-1"])
        XCTAssertEqual("yardr-dev-test-1", ext.get(key))
        XCTAssertTrue(ext.keys().contains(key))
        ext.write(remove: [key])
        XCTAssertNil(app.get(key))
    }
}
