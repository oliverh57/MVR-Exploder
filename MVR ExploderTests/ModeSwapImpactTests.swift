import XCTest
@testable import MVR_Exploder

/// What Mode Swap says a swap would do to the patch, before it's made.
final class ModeSwapImpactTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    /// The rig's type in two modes: 10 channels, or 40.
    private let footprints = [
        "Spot.gdtf": [
            GDTFFootprint(mode: "Standard", channelsByBreak: [1: 10]),
            GDTFFootprint(mode: "Big", channelsByBreak: [1: 40]),
        ],
    ]

    /// Three fixtures, patched back to back at the addresses given.
    private func rig(at addresses: [Int]) throws -> MVRDocument {
        let url = try MVRTestRig.write(MVRTestRig.bar("Spot", count: addresses.count, y: 0))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        document.setAddresses(Dictionary(uniqueKeysWithValues:
            zip(document.fixtures.map(\.id), addresses).map { ($0, $1) }))
        return document
    }

    private func impact(_ document: MVRDocument, moving: [MVRFixture], to mode: String) -> ModeSwapImpact {
        ModeSwapImpact.of(
            moving: Set(moving.map(\.id)), to: mode,
            fixtures: document.fixtures, footprints: footprints)
    }

    func testABiggerModeOnATightPatchIsFlagged() throws {
        let document = try rig(at: [1, 11, 21])

        let result = impact(document, moving: document.fixtures, to: "Big")

        XCTAssertEqual(result.channelChange, 30)
        XCTAssertTrue(result.isChecked)
        XCTAssertEqual(result.newOverlaps, 3, "1–40, 11–50 and 21–60 all overlap")
        XCTAssertEqual(result.newOverruns, 0)
    }

    func testABiggerModeWithRoomForItFits() throws {
        let document = try rig(at: [1, 41, 81])

        let result = impact(document, moving: document.fixtures, to: "Big")

        XCTAssertEqual(result.newOverlaps, 0)
        XCTAssertEqual(result.newOverruns, 0)
    }

    /// Moving one fixture can push it onto a neighbour that isn't moving.
    func testANeighbourThatIsntMovingCounts() throws {
        let document = try rig(at: [1, 11, 41])

        let result = impact(document, moving: [document.fixtures[0]], to: "Big")

        XCTAssertEqual(result.newOverlaps, 2, "the moved fixture and the one at 11")
    }

    func testRunningOffTheEndOfAUniverseIsFlagged() throws {
        let document = try rig(at: [490])

        let result = impact(document, moving: document.fixtures, to: "Big")

        XCTAssertEqual(result.newOverruns, 1, "490 + 40 runs to 529")
    }

    /// Fixtures already stacked on one address clash before and after;
    /// that isn't the swap's doing.
    func testAClashThatsAlreadyThereIsntNews() throws {
        let document = try rig(at: [1, 1, 41])

        let result = impact(document, moving: [document.fixtures[2]], to: "Big")

        XCTAssertEqual(result.newOverlaps, 0)
    }

    func testAModeTheGDTFDoesntHaveCantBeChecked() throws {
        let document = try rig(at: [1, 11])

        let result = impact(document, moving: document.fixtures, to: "Typed In")

        XCTAssertFalse(result.isChecked)
        XCTAssertNil(result.channelChange)
    }
}
