import XCTest
@testable import MVR_Exploder

/// Dragging cells round the Fixture ID map.
final class IDMapMoveTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    /// Spots on 101–103, washes on 201–202.
    private func rig() throws -> MVRDocument {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Spot", count: 3, y: 0, idsFrom: 101)
                + MVRTestRig.bar("Wash", count: 2, y: 3000, idsFrom: 201))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return document
    }

    private func id(of name: String, in document: MVRDocument) -> String {
        document.fixtures.first { $0.name == name }!.id
    }

    func testOneCellOntoAFreeIDMovesIt() throws {
        let document = try rig()
        let spot = id(of: "Spot 1", in: document)
        XCTAssertEqual(
            IDMapMove.plan(moving: [spot], from: 101, to: 150, in: document.fixtures),
            .moves([spot: 150]))
    }

    func testOneCellOntoAnotherSwapsThem() throws {
        let document = try rig()
        let spot = id(of: "Spot 1", in: document)
        let wash = id(of: "Wash 1", in: document)
        XCTAssertEqual(
            IDMapMove.plan(moving: [spot], from: 101, to: 201, in: document.fixtures),
            .moves([spot: 201, wash: 101]))
    }

    /// A selection keeps its spacing, and moving it along by one, into
    /// IDs it's leaving, is fine.
    func testASelectionMovesAsOne() throws {
        let document = try rig()
        let spots = ["Spot 1", "Spot 2", "Spot 3"].map { id(of: $0, in: document) }
        XCTAssertEqual(
            IDMapMove.plan(moving: Set(spots), from: 101, to: 102, in: document.fixtures),
            .moves([spots[0]: 102, spots[1]: 103, spots[2]: 104]))
    }

    func testASelectionWontLandOnOtherFixtures() throws {
        let document = try rig()
        let spots = ["Spot 1", "Spot 2", "Spot 3"].map { id(of: $0, in: document) }
        guard case .blocked(let reason) =
            IDMapMove.plan(moving: Set(spots), from: 101, to: 200, in: document.fixtures)
        else { return XCTFail("moved onto the washes") }
        XCTAssertTrue(reason.contains("201, 202"), reason)
    }

    func testNothingMovesBelowOne() throws {
        let document = try rig()
        let spots = ["Spot 1", "Spot 2"].map { id(of: $0, in: document) }
        XCTAssertEqual(
            IDMapMove.plan(moving: Set(spots), from: 102, to: 0, in: document.fixtures),
            .blocked("Fixture IDs start at 1."))
    }
}
