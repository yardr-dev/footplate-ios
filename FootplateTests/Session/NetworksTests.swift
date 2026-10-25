@testable import Footplate
import XCTest

// What NetworkWatch treats as an initial path and as a later path change.
final class NetworksTests: XCTestCase {
    func testTheInitialPathIsTheBaselineAndLaterUpdatesAreChanges() {
        var updates = NetworkPathUpdates()

        XCTAssertFalse(updates.received())
        XCTAssertTrue(updates.received())
        XCTAssertTrue(updates.received())
    }
}
