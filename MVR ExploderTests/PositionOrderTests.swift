import XCTest
@testable import MVR_Exploder

/// Ordering a whole list of fixtures by where they are — what the Disguise
/// CSV mode does when the order comes from position rather than the list.
final class PositionOrderTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    private func load(_ fixtures: [MVRTestRig.Fixture]) throws -> [MVRFixture] {
        let url = try MVRTestRig.write(fixtures)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return document.fixtures
    }

    /// A bar listed back to front still lays out left to right.
    func testTheListOrderIsReplacedByThePositionOrder() throws {
        let bar = MVRTestRig.bar("Line", count: 6, y: 0).reversed()
        let fixtures = try load(Array(bar))

        XCTAssertEqual(
            fixtures.map(\.name), ["Line 6", "Line 5", "Line 4", "Line 3", "Line 2", "Line 1"],
            "the file's own order, for contrast")

        let ordered = MVRAutoID.inOrder(fixtures: fixtures, strategy: .leftToRight)
        XCTAssertEqual(
            ordered.map(\.name), ["Line 1", "Line 2", "Line 3", "Line 4", "Line 5", "Line 6"])
    }

    /// Every fixture comes back, which is the difference between this and
    /// `orderedIDs` — a table showing the type can't quietly lose rows.
    func testNothingIsLost() throws {
        let fixtures = try load(MVRTestRig.bar("Line", count: 6, y: 0))
        let ordered = MVRAutoID.inOrder(fixtures: fixtures, strategy: .topToBottom)

        XCTAssertEqual(Set(ordered.map(\.id)), Set(fixtures.map(\.id)))
        XCTAssertEqual(ordered.count, fixtures.count)
    }

    /// The two agree: the placed fixtures come out in exactly the order
    /// the numbering would use.
    func testItMatchesTheNumberingOrder() throws {
        let fixtures = try load(MVRTestRig.bar("Line", count: 8, y: 0))
        for strategy in AutoIDOrderStrategy.allCases {
            let ordered = MVRAutoID.inOrder(fixtures: fixtures, strategy: strategy).map(\.id)
            let ids = MVRAutoID.orderedIDs(
                fixtures: fixtures, strategy: strategy, tolerance: .default)
            XCTAssertEqual(ordered, ids, "\(strategy.label)")
        }
    }

    /// A tower of pairs reads down each column, the same as the Smart Auto
    /// ID run would number it.
    func testATowerReadsDownEachColumn() throws {
        var rig: [MVRTestRig.Fixture] = []
        for level in 0..<4 {
            let z = 6800 - Double(level) * 850
            rig.append(MVRTestRig.Fixture(name: "L\(level + 1)", type: "Line", x: -100, y: 0, z: z))
            rig.append(MVRTestRig.Fixture(name: "R\(level + 1)", type: "Line", x: 100, y: 0, z: z))
        }
        let ordered = MVRAutoID.inOrder(
            fixtures: try load(rig), strategy: .columnsTopToBottom)

        XCTAssertEqual(
            ordered.map(\.name), ["L1", "L2", "L3", "L4", "R1", "R2", "R3", "R4"])
    }
}
