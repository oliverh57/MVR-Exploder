import XCTest
@testable import MVR_Exploder

/// Where a run begins, and that the number given is the number used.
final class StartingIDTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    func testTheDefaultIsOneHundredAndOne() throws {
        let session = try makeSession(MVRTestRig.bar("Spot", count: 4, y: 0))
        XCTAssertEqual(session.startingID, 101)
        XCTAssertEqual(session.plan.assignments.map(\.newID).min(), 101)
        XCTAssertFalse(session.hasCorrections, "the default is not a correction to save")
    }

    /// A type big enough to want a thousand-block used to drag the whole
    /// run up to 1001, because the first block was rounded to a boundary
    /// like every other. A start the user typed is a statement, not a hint.
    func testABigFirstTypeStillStartsWhereItWasTold() throws {
        let session = try makeSession(MVRTestRig.bar("Spot", count: 150, y: 0, spacing: 300))
        XCTAssertEqual(session.plan.assignments.map(\.newID).min(), 101)
    }

    func testLaterBlocksStillRoundToABoundary() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 4, y: 0) + MVRTestRig.bar("Wash", count: 4, y: 4000))
        let starts = session.plan.types.map(\.firstID).sorted()

        XCTAssertEqual(starts.first, 101, "the first block is the number given")
        XCTAssertEqual(starts.last! % 100, 1, "the ones after it land on a boundary")
        XCTAssertGreaterThan(starts.last!, starts.first!)
    }

    func testAChangedStartIsHonouredExactly() throws {
        let session = try makeSession(MVRTestRig.bar("Spot", count: 4, y: 0))
        session.startingID = 501
        XCTAssertEqual(session.plan.assignments.map(\.newID).sorted(), [501, 502, 503, 504])
        XCTAssertTrue(session.hasCorrections)
    }

    func testStartingFreshGoesBackToTheDefault() throws {
        let session = try makeSession(MVRTestRig.bar("Spot", count: 4, y: 0))
        session.startingID = 2001
        session.startFresh()
        XCTAssertEqual(session.startingID, 101)
    }

    private func makeSession(_ fixtures: [MVRTestRig.Fixture]) throws -> AutoIDSession {
        let url = try MVRTestRig.write(fixtures)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return AutoIDSession(fixtures: document.fixtures)
    }
}
