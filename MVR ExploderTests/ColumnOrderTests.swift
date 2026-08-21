import XCTest
@testable import MVR_Exploder

/// Tower mode: a tower carrying more than one fixture at each
/// height numbers each vertical line in full before starting the next.
final class ColumnOrderTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    /// A tower, 8 heights with a pair at each: 16 fixtures.
    /// Named "L1", "R1" … so the resulting order is readable.
    private func tower(pairSpacing: Double = 200, depthOffset: Double = 0) -> [MVRTestRig.Fixture] {
        var fixtures: [MVRTestRig.Fixture] = []
        for level in 0..<8 {
            let z = 6800 - Double(level) * 850
            fixtures.append(MVRTestRig.Fixture(
                name: "L\(level + 1)", type: "Bar", x: -pairSpacing / 2, y: 0, z: z))
            fixtures.append(MVRTestRig.Fixture(
                name: "R\(level + 1)", type: "Bar", x: pairSpacing / 2, y: depthOffset, z: z))
        }
        return fixtures
    }

    func testEachColumnIsNumberedInFullBeforeTheNext() throws {
        let order = try ordered(tower(), as: .columnsTopToBottom)

        XCTAssertEqual(order, [
            "L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8",
            "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8",
        ])
    }

    /// The contrast that makes the mode worth having: top-to-bottom reads
    /// the pair at each height before dropping a level.
    func testTopToBottomStillNumbersInPairs() throws {
        let order = try ordered(tower(), as: .topToBottom)

        XCTAssertEqual(Array(order.prefix(6)), ["L1", "R1", "L2", "R2", "L3", "R3"])
    }

    /// Two pairs at each height — four columns in plan, separated on both
    /// horizontal axes. Banding on whichever axis spreads more would read
    /// this as two columns of eight.
    func testTwoPairsAtEachHeightAreFourColumns() throws {
        var fixtures: [MVRTestRig.Fixture] = []
        for level in 0..<4 {
            let z = 6000 - Double(level) * 1500
            for (index, (x, y)) in [(-200.0, -300.0), (200.0, -300.0),
                                    (-200.0, 300.0), (200.0, 300.0)].enumerated() {
                fixtures.append(MVRTestRig.Fixture(
                    name: "C\(index + 1)-\(level + 1)", type: "Bar", x: x, y: y, z: z))
            }
        }

        let order = try ordered(fixtures, as: .columnsTopToBottom)

        // Four runs of four, each a single column top to bottom.
        XCTAssertEqual(order.count, 16)
        for start in stride(from: 0, to: 16, by: 4) {
            let column = order[start..<(start + 4)]
            let names = Set(column.map { $0.split(separator: "-")[0] })
            XCTAssertEqual(names.count, 1, "run \(start / 4) mixes columns: \(Array(column))")
            XCTAssertEqual(
                column.map { Int($0.split(separator: "-")[1])! }, [1, 2, 3, 4],
                "run \(start / 4) is not top to bottom")
        }
    }

    /// A column that leans — a tower raked back, or rigging tolerance —
    /// still reads as one column rather than one per fixture.
    func testAColumnThatLeansSlightlyIsStillOneColumn() throws {
        var fixtures = tower()
        for index in fixtures.indices where fixtures[index].name.hasPrefix("R") {
            // Drift the right-hand column by a few centimetres down its height.
            fixtures[index].x += Double(index) * 8
        }

        let order = try ordered(fixtures, as: .columnsTopToBottom)
        XCTAssertEqual(Array(order.prefix(8)),
                       ["L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8"])
    }

    /// On a flat horizontal run every fixture is its own column, so the
    /// mode degenerates to reading across — no reordering surprise.
    func testAStraightBarIsUnaffected() throws {
        let bar = MVRTestRig.bar("Bar", count: 6, y: 0)
        let columns = try ordered(bar, as: .columnsTopToBottom)
        let across = try ordered(bar, as: .leftToRight)
        XCTAssertEqual(columns, across)
    }

    func testTheModeIsOfferedInTheMenu() {
        XCTAssertTrue(AutoIDOrderStrategy.allCases.contains(.columnsTopToBottom))
        XCTAssertEqual(AutoIDOrderStrategy.columnsTopToBottom.label, "Tower (down each column)")
        XCTAssertEqual(
            AutoIDOrderStrategy.allCases.last, .columnsTopToBottom,
            "kept last so it cannot displace an existing suggestion")
    }

    // MARK: - Helpers

    private func ordered(
        _ fixtures: [MVRTestRig.Fixture], as strategy: AutoIDOrderStrategy
    ) throws -> [String] {
        let url = try MVRTestRig.write(fixtures)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")

        let ids = MVRAutoID.orderedIDs(
            fixtures: document.fixtures, strategy: strategy, tolerance: .default)
        let names = Dictionary(
            document.fixtures.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { names[$0] }
    }
}
