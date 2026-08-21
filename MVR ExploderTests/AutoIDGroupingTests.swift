import XCTest
@testable import MVR_Exploder

/// Bars are found, ordered downstage to upstage, and numbered along.
final class AutoIDGroupingTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    /// Four overhead bars at four depths: four groups, in depth order,
    /// named LX1 to LX4.
    ///
    /// The regression here is the row order. It used to band depth by the
    /// *grouping* distance — how far apart fixtures on one bar sit, around
    /// 3–4 m — so two bars 3 m apart fell in one band and were then ordered
    /// left to right. Types listed LX2, LX5, LX3, LX6: right numbers, wrong
    /// order, and the IDs were allocated in that wrong order too.
    func testBarsAreListedDownstageToUpstage() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 10, y: -3000)
                + MVRTestRig.bar("Spot", count: 10, y: 1900)
                + MVRTestRig.bar("Spot", count: 10, y: 5000)
                + MVRTestRig.bar("Spot", count: 10, y: 9200))
        let spec = session.displayTypes[0]

        XCTAssertEqual(session.groups(for: spec).count, 4)
        XCTAssertEqual(names(session, spec), ["LX1", "LX2", "LX3", "LX4"])
        XCTAssertEqual(depths(session, spec), depths(session, spec).sorted(),
                       "rows must run downstage to upstage")
    }

    /// The shape of the bug as reported: bars 3.1 m apart, the upstage one
    /// starting further stage-left. Ordering by anything but depth puts
    /// them the wrong way round.
    func testTwoBarsCloseInDepthStillOrderByDepth() throws {
        let session = try makeSession(
            MVRTestRig.bar("Spot", count: 10, y: 1900, centre: 2000)
                + MVRTestRig.bar("Spot", count: 12, y: 5000, centre: -3000))
        let spec = session.displayTypes[0]

        XCTAssertEqual(names(session, spec), ["LX1", "LX2"])
        XCTAssertEqual(session.groups(for: spec).map(\.count), [10, 12],
                       "the downstage bar of 10 comes first")
    }

    /// LX numbers run across the whole rig, so a type that isn't on the
    /// downstage bar starts partway up the count — correct, and confusing
    /// enough to need saying.
    func testATypeNotOnTheFirstBarStartsPartwayUpAndSaysSo() throws {
        let session = try makeSession(
            MVRTestRig.bar("Strobe", count: 6, y: -4000)
                + MVRTestRig.bar("Spot", count: 10, y: 0)
                + MVRTestRig.bar("Spot", count: 10, y: 4000))
        let spot = try XCTUnwrap(session.displayTypes.first { session.displayName(for: $0) == "Spot" })

        XCTAssertEqual(names(session, spot), ["LX2", "LX3"])
        let note = try XCTUnwrap(session.lowestBarNote(for: spot))
        XCTAssertTrue(note.contains("LX2"), note)
        XCTAssertTrue(note.contains("Strobe"), "should say where LX1 actually is: \(note)")
    }

    func testATypeOnTheFirstBarHasNothingToExplain() throws {
        let session = try makeSession(MVRTestRig.bar("Spot", count: 10, y: 0))
        XCTAssertNil(session.lowestBarNote(for: session.displayTypes[0]))
    }

    func testOneBarIsOneGroup() throws {
        let session = try makeSession(MVRTestRig.bar("Spot", count: 20, y: 0))
        XCTAssertEqual(session.groups(for: session.displayTypes[0]).count, 1)
    }

    // MARK: - Helpers

    private func makeSession(_ fixtures: [MVRTestRig.Fixture]) throws -> AutoIDSession {
        let url = try MVRTestRig.write(fixtures)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return AutoIDSession(fixtures: document.fixtures)
    }

    private func names(_ session: AutoIDSession, _ spec: String) -> [String] {
        session.groups(for: spec).indices.map { session.name(forGroup: $0, in: spec) }
    }

    private func depths(_ session: AutoIDSession, _ spec: String) -> [Double] {
        session.groups(for: spec).map { members in
            let ys = members.compactMap(\.position3D).map(\.y)
            return ys.reduce(0, +) / Double(max(ys.count, 1))
        }
    }
}
