import XCTest
@testable import MVR_Exploder

/// Laying fixtures out as a DMX screen and writing the CSV Disguise reads.
final class DisguisePixelMapTests: XCTestCase {

    /// A pixel line: 16 across, 2 high, RGB pixels three channels apart
    /// starting at the fixture's channel 6.
    private func pixelLineBlock() -> DisguisePixelMap.Block {
        var block = DisguisePixelMap.Block(columns: 16, rows: 2)
        for row in 0..<2 {
            for column in 0..<16 {
                block.setOffset(6 + (row * 16 + column) * 3, column: column, row: row)
            }
        }
        return block
    }

    // MARK: - The arithmetic

    /// The offset counts the fixture's own channels from 1, so a fixture
    /// at 1 with its first pixel at 6 lands on 6 — not 7.
    func testAPixelsChannelIsTheAddressPlusTheOffsetLessOne() {
        var block = DisguisePixelMap.Block(columns: 1, rows: 1)
        block.setOffset(6, column: 0, row: 0)

        let pixels = DisguisePixelMap.pixels(
            placements: [.init(address: 1, originX: 0, originY: 0)], block: block)

        XCTAssertEqual(pixels, [.init(x: 0, y: 0, universe: 1, channel: 6)])
    }

    /// Worked out absolutely and split at the end, so a block running off
    /// the end of a universe continues into the next rather than reporting
    /// a channel above 512.
    func testABlockRunningPastAUniverseContinuesIntoTheNext() {
        var block = DisguisePixelMap.Block(columns: 2, rows: 1)
        block.setOffset(1, column: 0, row: 0)
        block.setOffset(20, column: 1, row: 0)

        // Universe 3, channel 500.
        let address = 2 * 512 + 500
        let pixels = DisguisePixelMap.pixels(
            placements: [.init(address: address, originX: 0, originY: 0)], block: block)

        XCTAssertEqual(pixels[0], .init(x: 0, y: 0, universe: 3, channel: 500))
        XCTAssertEqual(pixels[1], .init(x: 1, y: 0, universe: 4, channel: 7))
    }

    func testACellNobodyFilledInIsLeftOut() {
        var block = DisguisePixelMap.Block(columns: 3, rows: 1)
        block.setOffset(1, column: 0, row: 0)
        block.setOffset(7, column: 2, row: 0)

        let pixels = DisguisePixelMap.pixels(
            placements: [.init(address: 1, originX: 0, originY: 0)], block: block)

        XCTAssertEqual(pixels.map(\.x), [0, 2], "the middle cell is unset, so it isn't written")
    }

    func testFixturesAreLaidOutSideBySide() {
        let block = pixelLineBlock()
        let placements = DisguisePixelMap.placements(addresses: [1, 118, 235], block: block)

        XCTAssertEqual(placements.map(\.originX), [0, 16, 32])
        XCTAssertEqual(placements.map(\.originY), [0, 0, 0])
    }

    // MARK: - Resizing

    /// Changing 16×2 to 16×3 must not throw away two rows of typing.
    func testResizingKeepsWhatStillFits() {
        var block = pixelLineBlock()
        block.resize(columns: 16, rows: 3)

        XCTAssertEqual(block.cellCount, 48)
        XCTAssertEqual(block.offset(column: 0, row: 0), 6)
        XCTAssertEqual(block.offset(column: 15, row: 1), 99)
        XCTAssertNil(block.offset(column: 0, row: 2), "the new row starts empty")
    }

    func testShrinkingDropsOnlyWhatNoLongerFits() {
        var block = pixelLineBlock()
        block.resize(columns: 8, rows: 2)

        XCTAssertEqual(block.cellCount, 16)
        XCTAssertEqual(block.offset(column: 7, row: 0), 6 + 7 * 3)
        XCTAssertEqual(block.offset(column: 0, row: 1), 6 + 16 * 3, "row 1 still starts where it did")
    }

    // MARK: - The real file

    /// The strongest check available: rebuild a CSV exported from Disguise
    /// for a real show — 24 pixel lines, 768 pixels — and compare it
    /// line for line.
    func testReproducesARealExportExactly() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "pixeline-reference", withExtension: "csv"))
        let expected = try String(contentsOf: url, encoding: .utf8)

        // The 24 lines are patched four to a universe, 117 channels apart,
        // starting fresh in each universe from 50.
        var addresses: [Int] = []
        for universe in 50...55 {
            for slot in 0..<4 {
                addresses.append((universe - 1) * 512 + 1 + slot * 117)
            }
        }

        let block = pixelLineBlock()
        let pixels = DisguisePixelMap.pixels(
            placements: DisguisePixelMap.placements(addresses: addresses, block: block),
            block: block)

        XCTAssertEqual(pixels.count, 768, "24 lines of 32 pixels")

        let produced = DisguisePixelMap.csv(pixels)
        let producedLines = produced.split(separator: "\n", omittingEmptySubsequences: true)
        let expectedLines = expected.split(whereSeparator: \.isNewline)

        XCTAssertEqual(producedLines.count, expectedLines.count)
        for (index, (mine, theirs)) in zip(producedLines, expectedLines).enumerated()
        where mine != theirs {
            XCTFail("line \(index + 1): produced \"\(mine)\", reference \"\(theirs)\"")
            break
        }
    }
}

/// Predicting the rest of a grid from the first pixel typed in.
final class PixelFillSuggestionTests: XCTestCase {

    private func empty(_ columns: Int, _ rows: Int) -> DisguisePixelMap.Block {
        DisguisePixelMap.Block(columns: columns, rows: rows)
    }

    /// The case this exists for: one number typed into the first pixel of
    /// a line, and the other 31 follow.
    func testOneTypedPixelPredictsTheWholeLine() {
        var block = empty(16, 2)
        block.setOffset(6, column: 0, row: 0)

        let suggested = block.suggestions(anchor: 0, value: 6, step: 3)

        XCTAssertEqual(suggested.count, 31, "every cell but the one typed")
        XCTAssertEqual(suggested[1], 9)
        XCTAssertEqual(suggested[15], 51, "end of the top row")
        XCTAssertEqual(suggested[16], 54, "start of the bottom row, continuing")
        XCTAssertEqual(suggested[31], 99, "last pixel of the line")
    }

    /// Accepting them has to produce exactly the layout the real export
    /// was built from.
    func testAcceptingThemGivesTheRealPixelLineLayout() {
        var block = empty(16, 2)
        block.setOffset(6, column: 0, row: 0)
        for (index, value) in block.suggestions(anchor: 0, value: 6, step: 3) {
            block.setOffset(value, column: index % 16, row: index / 16)
        }

        XCTAssertEqual(block.filledCount, 32)
        XCTAssertEqual((0..<32).map { block.offset(column: $0 % 16, row: $0 / 16) },
                       (0..<32).map { 6 + $0 * 3 })
    }

    /// A pixel somebody typed is an answer; a suggestion must not paint
    /// over it.
    func testCellsAlreadyFilledInAreLeftAlone() {
        var block = empty(4, 1)
        block.setOffset(1, column: 0, row: 0)
        block.setOffset(99, column: 2, row: 0)

        let suggested = block.suggestions(anchor: 0, value: 1, step: 3)

        XCTAssertEqual(Set(suggested.keys), [1, 3], "cell 2 was typed, so it is not suggested")
        XCTAssertEqual(suggested[3], 10)
    }

    func testSuggestionsNeverGoBelowChannelOne() {
        var block = empty(4, 1)
        block.setOffset(5, column: 3, row: 0)

        let suggested = block.suggestions(anchor: 3, value: 5, step: 3)

        XCTAssertNil(suggested[0], "would be -4")
        XCTAssertEqual(suggested[2], 2)
    }

    // MARK: - The gap

    func testTheGapIsReadFromTheTwoPixelsAlreadyFilledIn() {
        var block = empty(8, 1)
        block.setOffset(6, column: 0, row: 0)
        block.setOffset(10, column: 1, row: 0)
        XCTAssertEqual(block.inferredStep(), 4, "RGBW")
    }

    func testTheGapSpansTheCellsBetweenTwoFilledPixels() {
        var block = empty(8, 1)
        block.setOffset(1, column: 0, row: 0)
        block.setOffset(13, column: 4, row: 0)
        XCTAssertEqual(block.inferredStep(), 3, "12 over 4 cells")
    }

    func testOneFilledPixelFallsBackToAnRGBGap() {
        var block = empty(8, 1)
        block.setOffset(6, column: 0, row: 0)
        XCTAssertEqual(block.inferredStep(), 3)
    }

    func testAGapThatMakesNoSenseFallsBack() {
        var block = empty(8, 1)
        block.setOffset(50, column: 0, row: 0)
        block.setOffset(10, column: 1, row: 0)
        XCTAssertEqual(block.inferredStep(), 3, "descending is not a gap")
    }
}

/// Standing the fixtures on their end turns a line into a tower, and the
/// x,y coordinates have to follow.
final class PixelRotationTests: XCTestCase {

    private func line() -> DisguisePixelMap.Block {
        var block = DisguisePixelMap.Block(columns: 16, rows: 2)
        for row in 0..<2 {
            for column in 0..<16 {
                block.setOffset(6 + (row * 16 + column) * 3, column: column, row: row)
            }
        }
        return block
    }

    // MARK: - One fixture's cells

    func testTurningSwapsTheBlocksWidthAndHeight() {
        let block = line()
        XCTAssertEqual(DisguisePixelMap.size(of: block, rotation: .none).width, 16)
        XCTAssertEqual(DisguisePixelMap.size(of: block, rotation: .none).height, 2)
        XCTAssertEqual(DisguisePixelMap.size(of: block, rotation: .quarter).width, 2)
        XCTAssertEqual(DisguisePixelMap.size(of: block, rotation: .quarter).height, 16)
        XCTAssertEqual(DisguisePixelMap.size(of: block, rotation: .half).width, 16)
        XCTAssertEqual(DisguisePixelMap.size(of: block, rotation: .threeQuarter).width, 2)
    }

    /// Clockwise: the left-hand end of the line goes to the top.
    func testAQuarterTurnPutsTheFirstPixelTopRight() {
        let block = line()
        func at(_ c: Int, _ r: Int) -> (x: Int, y: Int) {
            DisguisePixelMap.position(column: c, row: r, block: block, rotation: .quarter)
        }
        XCTAssertEqual(at(0, 0).x, 1); XCTAssertEqual(at(0, 0).y, 0)
        XCTAssertEqual(at(0, 1).x, 0); XCTAssertEqual(at(0, 1).y, 0)
        XCTAssertEqual(at(15, 0).x, 1); XCTAssertEqual(at(15, 0).y, 15)
    }

    func testHalfATurnFlipsBothWays() {
        let block = line()
        let corner = DisguisePixelMap.position(column: 0, row: 0, block: block, rotation: .half)
        XCTAssertEqual(corner.x, 15)
        XCTAssertEqual(corner.y, 1)
    }

    /// Every rotation must still land each pixel on its own cell.
    func testNoRotationPutsTwoPixelsInTheSamePlace() {
        let block = line()
        for rotation in DisguisePixelMap.Rotation.allCases {
            var seen = Set<String>()
            for row in 0..<block.rows {
                for column in 0..<block.columns {
                    let p = DisguisePixelMap.position(
                        column: column, row: row, block: block, rotation: rotation)
                    XCTAssertTrue(seen.insert("\(p.x),\(p.y)").inserted,
                                  "\(rotation.label) collides at \(p)")
                }
            }
            XCTAssertEqual(seen.count, 32, "\(rotation.label)")
        }
    }

    // MARK: - The whole screen

    func testALineOfTwentyFourIs384By2() {
        let block = line()
        let addresses = (0..<24).map { 1 + $0 * 117 }
        let placements = DisguisePixelMap.placements(
            addresses: addresses, block: block, rotation: .none)
        let size = DisguisePixelMap.screenSize(
            placements: placements, block: block, rotation: .none)

        XCTAssertEqual(size.width, 384)
        XCTAssertEqual(size.height, 2)
    }

    /// The same 24 stood on end.
    func testATowerOfTwentyFourIs2By384() {
        let block = line()
        let addresses = (0..<24).map { 1 + $0 * 117 }
        let placements = DisguisePixelMap.placements(
            addresses: addresses, block: block, rotation: .quarter)
        let size = DisguisePixelMap.screenSize(
            placements: placements, block: block, rotation: .quarter)

        XCTAssertEqual(size.width, 2)
        XCTAssertEqual(size.height, 384)
        XCTAssertEqual(placements.map(\.originY).prefix(3), [0, 16, 32])
        XCTAssertEqual(Set(placements.map(\.originX)), [0], "stacked, not spread")
    }

    /// Turning changes where a pixel is, never which channel drives it.
    func testTurningMovesPixelsWithoutChangingTheirChannels() {
        let block = line()
        let addresses = [1, 118]

        func channels(_ rotation: DisguisePixelMap.Rotation) -> [Int] {
            DisguisePixelMap.pixels(
                placements: DisguisePixelMap.placements(
                    addresses: addresses, block: block, rotation: rotation),
                block: block, rotation: rotation)
                .map { ($0.universe - 1) * 512 + $0.channel }
                .sorted()
        }

        let flat = channels(.none)
        XCTAssertEqual(flat.count, 64)
        for rotation in DisguisePixelMap.Rotation.allCases {
            XCTAssertEqual(channels(rotation), flat, "\(rotation.label) changed the patch")
        }
    }

    /// Fixture by fixture, not globally by row. A real export runs a
    /// whole pixel line's two rows before starting the next line, and
    /// sorting the file by y would have looked tidier and been wrong.
    func testPixelsAreGroupedByFixture() {
        let block = line()
        let pixels = DisguisePixelMap.pixels(
            placements: DisguisePixelMap.placements(
                addresses: [1, 118], block: block, rotation: .quarter),
            block: block, rotation: .quarter)

        XCTAssertEqual(pixels.count, 64)
        // The first fixture occupies rows 0–15, the second 16–31.
        XCTAssertTrue(pixels.prefix(32).allSatisfy { $0.y < 16 })
        XCTAssertTrue(pixels.suffix(32).allSatisfy { $0.y >= 16 })
    }
}

/// The space left between one fixture and the next.
final class PixelGapTests: XCTestCase {

    private func line() -> DisguisePixelMap.Block {
        var block = DisguisePixelMap.Block(columns: 16, rows: 2)
        for row in 0..<2 {
            for column in 0..<16 {
                block.setOffset(6 + (row * 16 + column) * 3, column: column, row: row)
            }
        }
        return block
    }

    func testNoGapIsTheOldLayout() {
        let block = line()
        let addresses = [1, 118, 235]
        XCTAssertEqual(
            DisguisePixelMap.placements(addresses: addresses, block: block),
            DisguisePixelMap.placements(
                addresses: addresses, block: block, rotation: .none, gap: .none))
    }

    /// Zero means butted together: on a 6-wide block the next fixture's
    /// first pixel is at 6,0 — not 7,0.
    func testZeroGapButtsTheFixturesTogether() {
        let block = DisguisePixelMap.Block(columns: 6, rows: 2)
        let placements = DisguisePixelMap.placements(
            addresses: [1, 100], block: block, rotation: .none, gap: .none)

        XCTAssertEqual(placements.map(\.originX), [0, 6])
        XCTAssertEqual(placements.map(\.originY), [0, 0])
    }

    func testAGapAlongTheRowWidensThePitch() {
        let block = line()
        let placements = DisguisePixelMap.placements(
            addresses: [1, 118, 235], block: block, rotation: .none,
            gap: DisguisePixelMap.Gap(between: 6, across: 0))

        // 16 wide plus 6 of air.
        XCTAssertEqual(placements.map(\.originX), [0, 22, 44])
        XCTAssertEqual(placements.map(\.originY), [0, 0, 0])
    }

    func testAGapAcrossTheRowStaggersIt() {
        let block = line()
        let placements = DisguisePixelMap.placements(
            addresses: [1, 118, 235], block: block, rotation: .none,
            gap: DisguisePixelMap.Gap(between: 0, across: 3))

        XCTAssertEqual(placements.map(\.originX), [0, 16, 32], "still butted together")
        XCTAssertEqual(placements.map(\.originY), [0, 3, 6], "and climbing")
    }

    /// Stood on end the fixtures stack, so the gap that spaces them out is
    /// the Y one.
    func testUprightFixturesAreSpacedDownTheScreen() {
        let block = line()
        let placements = DisguisePixelMap.placements(
            addresses: [1, 118], block: block, rotation: .quarter,
            gap: DisguisePixelMap.Gap(between: 2, across: 4))

        XCTAssertEqual(placements.map(\.originY), [0, 18], "16 high plus 2")
        XCTAssertEqual(placements.map(\.originX), [0, 4], "and stepped across")
    }

    /// The reported bug: a gap set on a row turned into a diagonal step
    /// once the fixtures were stood on end, because the number was tied to
    /// a screen axis rather than to the way the fixtures run.
    func testTheSameGapKeepsATowerStraight() {
        let block = line()
        let gap = DisguisePixelMap.Gap(between: 6, across: 0)

        let flat = DisguisePixelMap.placements(
            addresses: [1, 118], block: block, rotation: .none, gap: gap)
        XCTAssertEqual(flat.map(\.originX), [0, 22])
        XCTAssertEqual(flat.map(\.originY), [0, 0])

        let upright = DisguisePixelMap.placements(
            addresses: [1, 118], block: block, rotation: .quarter, gap: gap)
        XCTAssertEqual(upright.map(\.originX), [0, 0], "still one column")
        XCTAssertEqual(upright.map(\.originY), [0, 22], "16 high plus 6")
    }

    func testTheScreenGrowsByTheGap() {
        let block = line()
        let gapped = DisguisePixelMap.placements(
            addresses: [1, 118, 235], block: block, rotation: .none,
            gap: DisguisePixelMap.Gap(between: 6, across: 0))
        let size = DisguisePixelMap.screenSize(
            placements: gapped, block: block, rotation: .none)

        // Three 16-wide blocks and two 6-pixel gaps.
        XCTAssertEqual(size.width, 60)
        XCTAssertEqual(size.height, 2)
    }

    /// A stagger puts the widest and the tallest on different fixtures,
    /// which is why the size is taken over all of them.
    func testAStaggeredScreenIsMeasuredOverEveryFixture() {
        let block = line()
        let placements = DisguisePixelMap.placements(
            addresses: [1, 118], block: block, rotation: .none,
            gap: DisguisePixelMap.Gap(between: 0, across: 5))
        let size = DisguisePixelMap.screenSize(
            placements: placements, block: block, rotation: .none)

        XCTAssertEqual(size.width, 32)
        XCTAssertEqual(size.height, 7, "second block starts 5 down and is 2 high")
    }

    /// The gap moves pixels on the screen. It must not touch the patch.
    func testAGapLeavesEveryChannelAlone() {
        let block = line()
        let addresses = [1, 118, 235]

        func channels(_ gap: DisguisePixelMap.Gap) -> [Int] {
            DisguisePixelMap.pixels(
                placements: DisguisePixelMap.placements(
                    addresses: addresses, block: block, rotation: .none, gap: gap),
                block: block, rotation: .none)
                .map { ($0.universe - 1) * 512 + $0.channel }
        }

        XCTAssertEqual(channels(DisguisePixelMap.Gap(between: 6, across: 2)), channels(.none))
    }

    /// Nothing lands on top of anything else once there is air between
    /// the fixtures.
    func testGappedFixturesDoNotOverlap() {
        let block = line()
        let pixels = DisguisePixelMap.pixels(
            placements: DisguisePixelMap.placements(
                addresses: [1, 118, 235], block: block, rotation: .none,
                gap: DisguisePixelMap.Gap(between: 6, across: 0)),
            block: block, rotation: .none)

        let squares = Set(pixels.map { [$0.x, $0.y] })
        XCTAssertEqual(squares.count, pixels.count)
        // And the air is genuinely empty.
        XCTAssertFalse(squares.contains([16, 0]))
        XCTAssertFalse(squares.contains([21, 1]))
        XCTAssertTrue(squares.contains([22, 0]))
    }
}

/// Which way the pixels are counted inside one fixture.
final class PixelOrderTests: XCTestCase {

    private func block(_ order: DisguisePixelMap.PixelOrder) -> DisguisePixelMap.Block {
        DisguisePixelMap.Block(columns: 4, rows: 2, order: order)
    }

    func testRowsCountLeftToRightEveryRow() {
        XCTAssertEqual(block(.rows).sequence, [0, 1, 2, 3, 4, 5, 6, 7])
    }

    func testSnakingRowsDoubleBack() {
        XCTAssertEqual(block(.rowsZigZag).sequence, [0, 1, 2, 3, 7, 6, 5, 4])
    }

    func testColumnsCountDownward() {
        XCTAssertEqual(block(.columns).sequence, [0, 4, 1, 5, 2, 6, 3, 7])
    }

    func testSnakingColumnsDoubleBack() {
        XCTAssertEqual(block(.columnsZigZag).sequence, [0, 4, 5, 1, 2, 6, 7, 3])
    }

    /// Every cell is counted exactly once, whichever way round.
    func testEveryPixelIsCountedOnce() {
        for order in DisguisePixelMap.PixelOrder.allCases {
            XCTAssertEqual(block(order).sequence.sorted(), Array(0..<8), order.label)
        }
    }

    /// The fill counts along the order, so a snaking fixture's offsets
    /// snake with it: the cell after 3 on the top row is the one *below*
    /// it, not the one at the start of row two.
    func testSuggestionsFollowTheSnake() {
        var snake = block(.rowsZigZag)
        snake.setOffset(1, column: 0, row: 0)
        let suggested = snake.suggestions(anchor: 0, value: 1, step: 3)

        XCTAssertEqual(suggested[3], 10, "end of the top row is pixel 4")
        XCTAssertEqual(suggested[7], 13, "and pixel 5 is directly below it")
        XCTAssertEqual(suggested[4], 22, "the far end of row two is pixel 8")
    }

    /// The CSV's rows follow the count too.
    func testPixelsComeOutInPixelOrder() {
        var snake = block(.rowsZigZag)
        for index in 0..<8 {
            let cell = snake.sequence[index]
            snake.setOffset(1 + index * 3, column: cell % 4, row: cell / 4)
        }
        let pixels = DisguisePixelMap.pixels(
            placements: DisguisePixelMap.placements(addresses: [1], block: snake),
            block: snake)

        XCTAssertEqual(pixels.map(\.channel), [1, 4, 7, 10, 13, 16, 19, 22])
        // Pixel 5 sits under pixel 4, which is what snaking means.
        XCTAssertEqual([pixels[3].x, pixels[3].y], [3, 0])
        XCTAssertEqual([pixels[4].x, pixels[4].y], [3, 1])
    }

    /// The default is unchanged, which is what keeps the reference file
    /// reproducing.
    func testRowsIsTheDefault() {
        XCTAssertEqual(DisguisePixelMap.Block(columns: 4, rows: 2).order, .rows)
    }
}

/// Which corner the count starts from.
final class PixelStartCornerTests: XCTestCase {

    private func block(
        _ start: DisguisePixelMap.PixelStart,
        order: DisguisePixelMap.PixelOrder = .rows
    ) -> DisguisePixelMap.Block {
        DisguisePixelMap.Block(columns: 4, rows: 2, order: order, start: start)
    }

    func testTopLeftIsTheDefault() {
        XCTAssertEqual(DisguisePixelMap.Block(columns: 4, rows: 2).start, .topLeft)
        XCTAssertEqual(block(.topLeft).sequence, [0, 1, 2, 3, 4, 5, 6, 7])
    }

    func testTopRightCountsBackAlongEachRow() {
        XCTAssertEqual(block(.topRight).sequence, [3, 2, 1, 0, 7, 6, 5, 4])
    }

    func testBottomLeftStartsOnTheLastRow() {
        XCTAssertEqual(block(.bottomLeft).sequence, [4, 5, 6, 7, 0, 1, 2, 3])
    }

    func testBottomRightStartsInTheFarCorner() {
        XCTAssertEqual(block(.bottomRight).sequence, [7, 6, 5, 4, 3, 2, 1, 0])
    }

    func testEveryCornerCountsEveryPixelOnce() {
        for start in DisguisePixelMap.PixelStart.allCases {
            for order in DisguisePixelMap.PixelOrder.allCases {
                XCTAssertEqual(
                    block(start, order: order).sequence.sorted(), Array(0..<8),
                    "\(start.label), \(order.label)")
            }
        }
    }

    /// The reason the corner exists: turned 90°, a line counted from the
    /// top left puts pixel 1 on the *right* of the screen. Starting from
    /// the bottom left brings it back to the left.
    func testTurnedNinetyDegreesTheBottomLeftPutsPixelOneOnTheLeft() {
        func firstPixelX(_ start: DisguisePixelMap.PixelStart) -> Int {
            var line = DisguisePixelMap.Block(columns: 16, rows: 2, start: start)
            for index in 0..<line.cellCount {
                let cell = line.sequence[index]
                line.setOffset(1 + index * 3, column: cell % 16, row: cell / 16)
            }
            let pixels = DisguisePixelMap.pixels(
                placements: DisguisePixelMap.placements(
                    addresses: [1], block: line, rotation: .quarter),
                block: line, rotation: .quarter)
            return pixels[0].x
        }

        XCTAssertEqual(firstPixelX(.topLeft), 1, "on the right, as reported")
        XCTAssertEqual(firstPixelX(.bottomLeft), 0, "and now on the left")
    }
}
