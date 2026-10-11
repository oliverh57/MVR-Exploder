import XCTest
@testable import MVR_Exploder

/// Telling whether a GitHub release tag is newer than the running app.
final class UpdaterTests: XCTestCase {

    /// Tags are "v1.3.0" while the app says "1.3": the same version.
    func testATagMatchesTheAppsShorterVersion() {
        XCTAssertFalse(Updater.isNewer("v1.3.0", than: "1.3"))
        XCTAssertFalse(Updater.isNewer("1.3", than: "1.3.0"))
    }

    func testLaterVersionsAreNewer() {
        XCTAssertTrue(Updater.isNewer("v1.4.0", than: "1.3"))
        XCTAssertTrue(Updater.isNewer("1.3.1", than: "1.3"))
        XCTAssertTrue(Updater.isNewer("2.0", than: "1.9.9"))
    }

    /// Compared as numbers, not text: 1.10 comes after 1.9.
    func testPartsCompareAsNumbers() {
        XCTAssertTrue(Updater.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(Updater.isNewer("1.9", than: "1.10"))
    }

    func testEarlierVersionsAreNotNewer() {
        XCTAssertFalse(Updater.isNewer("v1.2.0", than: "1.3"))
    }
}
