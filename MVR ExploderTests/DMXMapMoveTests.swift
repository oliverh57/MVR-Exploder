import XCTest
@testable import MVR_Exploder

/// Dragging fixtures round the DMX universe map.
final class DMXMapMoveTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    /// Spots on 1.1, 1.21 and 1.41, twenty channels each.
    private func rig() throws -> (MVRDocument, [String], [String: Int]) {
        let url = try MVRTestRig.write(MVRTestRig.bar("Spot", count: 3, y: 0, idsFrom: 101))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        let spots = ["Spot 1", "Spot 2", "Spot 3"].map { name in
            document.fixtures.first { $0.name == name }!.id
        }
        document.setAddresses([spots[0]: 1, spots[1]: 21, spots[2]: 41])
        return (document, spots, Dictionary(uniqueKeysWithValues: spots.map { ($0, 20) }))
    }

    func testOneFixtureOntoFreeChannelsMovesIt() throws {
        let (document, spots, widths) = try rig()
        XCTAssertEqual(
            DMXMapMove.plan(moving: [spots[0]], from: 1, to: 101, in: document.fixtures, widths: widths),
            .moves([spots[0]: 101]))
    }

    /// Grabbed by its tenth channel, it lands with that channel on the drop.
    func testWhereItsGrabbedIsKept() throws {
        let (document, spots, widths) = try rig()
        XCTAssertEqual(
            DMXMapMove.plan(moving: [spots[2]], from: 50, to: 110, in: document.fixtures, widths: widths),
            .moves([spots[2]: 101]))
    }

    func testItWontLandOnAnotherFixturesChannels() throws {
        let (document, spots, widths) = try rig()
        // 1.35–1.54 runs back into Spot 2's last channels, 1.21–1.40.
        XCTAssertEqual(
            DMXMapMove.plan(moving: [spots[2]], from: 41, to: 35, in: document.fixtures, widths: widths),
            .blocked("Not moved: 1.21 is in the way."))
    }

    func testItWontRunPastTheEndOfAUniverse() throws {
        let (document, spots, widths) = try rig()
        XCTAssertEqual(
            DMXMapMove.plan(moving: [spots[2]], from: 41, to: 500, in: document.fixtures, widths: widths),
            .blocked("Not moved: Spot 3 would run past channel 512."))
    }

    /// A selection keeps its spacing, and moving it into channels it's
    /// leaving is fine.
    func testASelectionMovesAsOne() throws {
        let (document, spots, widths) = try rig()
        XCTAssertEqual(
            DMXMapMove.plan(moving: Set(spots), from: 1, to: 11, in: document.fixtures, widths: widths),
            .moves([spots[0]: 11, spots[1]: 31, spots[2]: 51]))
    }

    func testAMoveCanCrossIntoTheNextUniverse() throws {
        let (document, spots, widths) = try rig()
        XCTAssertEqual(
            DMXMapMove.plan(moving: [spots[0]], from: 1, to: 513, in: document.fixtures, widths: widths),
            .moves([spots[0]: 513]))
    }

    /// No width from the GDTF: one channel, as the map draws it.
    func testAnUnknownWidthCountsAsOneChannel() throws {
        let (document, spots, _) = try rig()
        XCTAssertEqual(
            DMXMapMove.plan(moving: [spots[0]], from: 1, to: 40, in: document.fixtures, widths: [:]),
            .moves([spots[0]: 40]))
    }

    // MARK: - Whole universes

    func testAUniverseMovesWithItsChannels() throws {
        let (document, spots, widths) = try rig()
        XCTAssertEqual(
            DMXMapMove.plan(universes: [1], to: 3, in: document.fixtures, widths: widths),
            .moves([spots[0]: 1025, spots[1]: 1045, spots[2]: 1065]))
    }

    /// Universes 1 and 3 moved to 5 become 5 and 6.
    func testMovedUniversesFollowOnInOrder() throws {
        let (document, spots, widths) = try rig()
        document.setAddresses([spots[2]: 1024 + 41])
        XCTAssertEqual(
            DMXMapMove.plan(universes: [1, 3], to: 5, in: document.fixtures, widths: widths),
            .moves([spots[0]: 2049, spots[1]: 2069, spots[2]: 2601]))
    }

    /// Universes 1 and 3 offset by 2 become 3 and 5.
    func testAnOffsetKeepsTheGaps() throws {
        let (document, spots, widths) = try rig()
        document.setAddresses([spots[2]: 1024 + 41])
        XCTAssertEqual(
            DMXMapMove.plan(universes: [1, 3], offsetBy: 2, in: document.fixtures, widths: widths),
            .moves([spots[0]: 1025, spots[1]: 1045, spots[2]: 2089]))
    }

    func testAUniverseWontLandOnAnothersFixtures() throws {
        let (document, spots, widths) = try rig()
        // Spot 3 on 2.30–2.49, where Spot 2 (1.21–1.40) would land.
        document.setAddresses([spots[2]: 512 + 30])
        XCTAssertEqual(
            DMXMapMove.plan(universes: [1], to: 2, in: document.fixtures, widths: widths),
            .blocked("Not moved: 2.30 is in the way."))
    }

    /// Universes 1 and 2 up by one: 1 lands on 2 as 2 moves off it.
    func testUniversesCanMoveIntoOnesBeingVacated() throws {
        let (document, spots, widths) = try rig()
        document.setAddresses([spots[2]: 513])
        XCTAssertEqual(
            DMXMapMove.plan(universes: [1, 2], offsetBy: 1, in: document.fixtures, widths: widths),
            .moves([spots[0]: 513, spots[1]: 533, spots[2]: 1025]))
    }

    func testUniversesStartAtOne() throws {
        let (document, _, widths) = try rig()
        XCTAssertEqual(
            DMXMapMove.plan(universes: [1], offsetBy: -1, in: document.fixtures, widths: widths),
            .blocked("Universes start at 1."))
    }
}
