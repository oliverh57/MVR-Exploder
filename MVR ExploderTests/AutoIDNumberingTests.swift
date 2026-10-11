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
        XCTAssertEqual(ids(session), [101, 102, 103, 104, 105])
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
            betweenGroups: false, betweenFixtures: true, fixtureGap: 1)
        XCTAssertEqual(ids(session), [101, 103, 105, 107])
    }

    func testGroupsStartOnRoundNumbers() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 3, y: 0) + MVRTestRig.bar("Spot", count: 3, y: 5000))
        session.gaps = AutoIDGaps(
            betweenGroups: true, betweenFixtures: false, fixtureGap: 1)
        XCTAssertEqual(ids(session), [101, 102, 103, 111, 112, 113])
    }

    /// The step is the type's biggest group rounded up to 10, 20, 50, 100…
    /// and every group of the type uses it, small ones included.
    func testTheStepFitsTheBiggestGroup() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 12, y: 0) + MVRTestRig.bar("Spot", count: 3, y: 5000))
        session.gaps = AutoIDGaps(
            betweenGroups: true, betweenFixtures: false, fixtureGap: 1)
        // Steps of 20 whichever bar is numbered first.
        let twelveFirst = Array(101...112) + Array(121...123)
        let threeFirst = Array(101...103) + Array(121...132)
        XCTAssertTrue([twelveFirst, threeFirst].contains(ids(session)), "\(ids(session))")
    }

    func testStrideLadder() {
        let gaps = AutoIDGaps(betweenGroups: true, betweenFixtures: false, fixtureGap: 1)
        XCTAssertEqual(gaps.groupStride(groupSizes: [7, 8, 6]), 10)
        XCTAssertEqual(gaps.groupStride(groupSizes: [10]), 10)
        XCTAssertEqual(gaps.groupStride(groupSizes: [11, 4]), 20)
        XCTAssertEqual(gaps.groupStride(groupSizes: [30, 24]), 50)
        XCTAssertEqual(gaps.groupStride(groupSizes: [51]), 100)
        XCTAssertEqual(gaps.groupStride(groupSizes: [120]), 200)
        XCTAssertNil(AutoIDGaps().groupStride(groupSizes: [8]))
    }

    /// With a gap between fixtures, a group's width is what it spans, not
    /// how many fixtures it has: 6 fixtures at a step of 2 span 11 IDs.
    func testTheStepAllowsForTheGapBetweenFixtures() {
        let gaps = AutoIDGaps(betweenGroups: true, betweenFixtures: true, fixtureGap: 1)
        XCTAssertEqual(gaps.groupStride(groupSizes: [6]), 20)
    }

    func testGapsOffChangeNothing() throws {
        let fixtures = MVRTestRig.bar("Spot", count: 3, y: 0)
            + MVRTestRig.bar("Spot", count: 3, y: 5000)
        let plain = try makeSession(fixtures)
        let expected = ids(plain)

        let session = try makeSession(fixtures)
        session.gaps = AutoIDGaps(
            betweenGroups: false, betweenFixtures: false, fixtureGap: 4)
        XCTAssertEqual(ids(session), expected)
    }

    func testABlockIsSizedForTheGapsItCarries() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 60, y: 0) + MVRTestRig.bar("Wash", count: 4, y: 5000))
        session.gaps = AutoIDGaps(
            betweenGroups: false, betweenFixtures: true, fixtureGap: 1)

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

        XCTAssertEqual(ids(session), [101, 102, 103, 2001, 2002, 2003, 2004, 2005, 2006])
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
