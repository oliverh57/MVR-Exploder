import XCTest
@testable import MVR_Exploder

/// What ID each fixture ends up with: blocks, gaps and pinned starts.
final class AutoIDNumberingTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    func testOneBarNumbersStraightThroughFromTheStartingID() throws {
        let session = try makeSession(MVRTestRig.bar("Spot", count: 5, y: 0))
        XCTAssertEqual(ids(session), [1001, 1002, 1003, 1004, 1005])
    }

    func testEachTypeGetsItsOwnBlock() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 5, y: 0) + MVRTestRig.bar("Wash", count: 4, y: 3000))
        let blocks = session.plan.types.map { ($0.firstID, $0.lastID) }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertLessThan(blocks[0].1, blocks[1].0, "blocks must not overlap")
        XCTAssertEqual(blocks[1].0 % 100, 1, "a block starts on a round hundred")
    }

    // MARK: - Gaps

    func testGapBetweenFixturesLeavesSpareIDs() throws {
        let session = try makeSession(MVRTestRig.bar("Spot", count: 4, y: 0))
        session.gaps = AutoIDGaps(
            betweenGroups: false, groupGap: 10, betweenFixtures: true, fixtureGap: 1)
        XCTAssertEqual(ids(session), [1001, 1003, 1005, 1007])
    }

    func testGapBetweenGroupsLeavesSpareIDs() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 3, y: 0) + MVRTestRig.bar("Spot", count: 3, y: 5000))
        session.gaps = AutoIDGaps(
            betweenGroups: true, groupGap: 10, betweenFixtures: false, fixtureGap: 1)
        // 1001–1003, ten spare, then 1014.
        XCTAssertEqual(ids(session), [1001, 1002, 1003, 1014, 1015, 1016])
    }

    func testGapsOffChangeNothing() throws {
        let fixtures = MVRTestRig.bar("Spot", count: 3, y: 0)
            + MVRTestRig.bar("Spot", count: 3, y: 5000)
        let plain = try makeSession(fixtures)
        let expected = ids(plain)

        let session = try makeSession(fixtures)
        session.gaps = AutoIDGaps(
            betweenGroups: false, groupGap: 25, betweenFixtures: false, fixtureGap: 4)
        XCTAssertEqual(ids(session), expected)
    }

    func testABlockIsSizedForTheGapsItCarries() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 60, y: 0) + MVRTestRig.bar("Wash", count: 4, y: 5000))
        session.gaps = AutoIDGaps(
            betweenGroups: false, groupGap: 10, betweenFixtures: true, fixtureGap: 1)

        let blocks = session.plan.types.map { ($0.firstID, $0.lastID) }.sorted { $0.0 < $1.0 }
        XCTAssertLessThan(blocks[0].1, blocks[1].0,
                          "60 fixtures at a step of 2 span 119 IDs and must not run into the next type")
    }

    // MARK: - Pinned starts

    func testPinningATypeStartIsHonoured() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 4, y: 0) + MVRTestRig.bar("Wash", count: 4, y: 3000))
        let wash = try XCTUnwrap(session.displayTypes.first { session.displayName(for: $0) == "Wash" })

        session.setStartingID(5001, forType: wash)

        let assigned = session.plan.assignments
            .filter { $0.spec == wash }.map(\.newID).sorted()
        XCTAssertEqual(assigned, [5001, 5002, 5003, 5004])
    }

    func testPinningAGroupStartIsHonouredAndTheRestFollowOn() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 3, y: 0)
                + MVRTestRig.bar("Spot", count: 3, y: 5000)
                + MVRTestRig.bar("Spot", count: 3, y: 10000))
        let spec = session.displayTypes[0]

        session.setStartingID(2001, forGroup: 1, in: spec)

        XCTAssertEqual(ids(session), [1001, 1002, 1003, 2001, 2002, 2003, 2004, 2005, 2006])
    }

    func testNoCollisionsInAPlainRun() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 12, y: 0)
                + MVRTestRig.bar("Wash", count: 9, y: 4000)
                + MVRTestRig.bar("Strobe", count: 7, y: 8000))
        XCTAssertEqual(session.plan.collisions, [])
        XCTAssertEqual(Set(session.plan.assignments.map(\.newID)).count, 28, "every ID distinct")
    }

    // MARK: - Helpers

    private func makeSession(_ fixtures: [MVRTestRig.Fixture]) throws -> AutoIDSession {
        let url = try MVRTestRig.write(fixtures)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return AutoIDSession(fixtures: document.fixtures)
    }

    private func ids(_ session: AutoIDSession) -> [Int] {
        session.plan.assignments.map(\.newID).sorted()
    }
}
