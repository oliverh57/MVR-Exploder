import XCTest
@testable import MVR_Exploder

/// The universe map finds the cell under the pointer by arithmetic rather
/// than by asking the views, so the arithmetic has to agree with where the
/// cells are drawn.
final class DMXMapLayoutTests: XCTestCase {

    /// Universes 1, 2 and 5 — so 3 and 4 are a gap line — 25 to a row.
    private let layout = DMXMapLayout(
        universes: [1, 2, 5], columns: 25, size: 40, spacing: 3, cellHeight: 24)

    private func centre(of address: Int) -> CGPoint {
        let rect = layout.rect(of: address)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func testEveryCellIsFoundWhereItsDrawn() {
        for address in [1, 2, 25, 26, 500, 501, 512, 513, 1024, 2049, 2073, 2560] {
            XCTAssertEqual(layout.address(at: centre(of: address)), address, "address \(address)")
        }
    }

    /// 512 doesn't divide by 25: the last row of a universe is 12 cells,
    /// and the space after them is nothing.
    func testTheShortLastRowEndsAt512() {
        let last = layout.rect(of: 512)
        XCTAssertEqual(layout.address(at: CGPoint(x: last.maxX + 50, y: last.midY)), nil)
        XCTAssertEqual(layout.rect(of: 501).minX, 0)
    }

    func testHeadingsAndTheGapAreNotCells() {
        // Universe 1's heading, above its first row.
        XCTAssertNil(layout.address(at: CGPoint(x: 10, y: 5)))
        // Between universe 2's last row and universe 5's first: the gap
        // line and universe 5's heading.
        let endOfTwo = layout.rect(of: 1024)
        let startOfFive = layout.rect(of: 2049)
        XCTAssertGreaterThan(startOfFive.minY - endOfTwo.maxY,
                             DMXMapLayout.gapHeight + DMXMapLayout.headingHeight - 1)
        XCTAssertNil(layout.address(at: CGPoint(x: 10, y: endOfTwo.maxY + 10)))
        XCTAssertNil(layout.address(at: CGPoint(x: 10, y: startOfFive.minY - 5)))
    }

    /// A run of channels is one rectangle, as wide as the cells and the
    /// spaces between them.
    func testARunSpansItsCells() {
        let run = layout.rect(of: 101, count: 5)
        XCTAssertEqual(run.minX, layout.rect(of: 101).minX)
        XCTAssertEqual(run.maxX, layout.rect(of: 105).maxX)
    }
}
