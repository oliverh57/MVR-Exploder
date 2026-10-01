import Foundation

/// A pixel map for Disguise: where each of a fixture's pixels sits on the
/// screen, and which DMX channel drives it.
///
/// Disguise wants one row per pixel — `x,y,universe,channel` — describing a
/// DMX screen. An MVR knows where the fixtures are and what they are
/// addressed at, but nothing in it says how a fixture's channels map to
/// pixels: that is the fixture's own layout, and the user supplies it once
/// per type.
struct DisguisePixelMap {

    /// One fixture type's layout, in cells.
    ///
    /// A pixel line is 16 across and 2 high; offsets are counted from the
    /// fixture's own address, so a line patched at 1 with its first pixel
    /// at 6 has offset 6 in the top-left cell. Nil means a cell nobody has
    /// filled in, and an unfilled cell is simply left out of the CSV rather
    /// than guessed at.
    struct Block: Equatable {
        var columns: Int
        var rows: Int
        /// Row-major, `rows * columns` entries.
        var offsets: [Int?]

        init(columns: Int, rows: Int, offsets: [Int?] = []) {
            self.columns = max(1, columns)
            self.rows = max(1, rows)
            self.offsets = Self.resized(offsets, to: self.rows * self.columns)
        }

        var cellCount: Int { rows * columns }
        var filledCount: Int { offsets.compactMap { $0 }.count }

        func offset(column: Int, row: Int) -> Int? {
            let index = row * columns + column
            return offsets.indices.contains(index) ? offsets[index] : nil
        }

        mutating func setOffset(_ value: Int?, column: Int, row: Int) {
            let index = row * columns + column
            guard offsets.indices.contains(index) else { return }
            offsets[index] = value
        }

        /// Keeps what fits when the grid is resized, so changing 16×2 to
        /// 16×3 doesn't throw away two rows of typing.
        mutating func resize(columns newColumns: Int, rows newRows: Int) {
            let newColumns = max(1, newColumns)
            let newRows = max(1, newRows)
            var moved = [Int?](repeating: nil, count: newColumns * newRows)
            for row in 0..<min(rows, newRows) {
                for column in 0..<min(columns, newColumns) {
                    moved[row * newColumns + column] = offset(column: column, row: row)
                }
            }
            columns = newColumns
            rows = newRows
            offsets = moved
        }

        /// What every empty cell would be, counting up from one that has
        /// been filled in.
        ///
        /// Typing an offset into all 32 pixels of a line is the same
        /// number over and over at a fixed gap, so the first is enough to
        /// predict the rest. Cells already filled in are left alone: a
        /// pixel somebody typed is an answer, and a suggestion that
        /// painted over it would lose work on a slip.
        func suggestions(anchor: Int, value: Int, step: Int) -> [Int: Int] {
            guard offsets.indices.contains(anchor), step != 0 else { return [:] }
            var result: [Int: Int] = [:]
            for index in offsets.indices where index != anchor && offsets[index] == nil {
                let suggested = value + (index - anchor) * step
                guard suggested >= 1 else { continue }
                result[index] = suggested
            }
            return result
        }

        /// The gap the grid itself implies, from the last two cells filled
        /// in. One RGB pixel when there aren't two to compare.
        func inferredStep(fallback: Int = 3) -> Int {
            let filled = offsets.enumerated().compactMap { index, value in
                value.map { (index: index, value: $0) }
            }
            guard filled.count >= 2 else { return fallback }
            let last = filled[filled.count - 1]
            let previous = filled[filled.count - 2]
            let span = last.index - previous.index
            guard span > 0 else { return fallback }
            let step = (last.value - previous.value) / span
            return step > 0 ? step : fallback
        }

        private static func resized(_ offsets: [Int?], to count: Int) -> [Int?] {
            if offsets.count == count { return offsets }
            if offsets.count > count { return Array(offsets.prefix(count)) }
            return offsets + [Int?](repeating: nil, count: count - offsets.count)
        }
    }

    /// Which way round the fixture is hung.
    ///
    /// A pixel line on its side is a tower, and the two produce different
    /// screens from the same fixture: 24 lines side by side are 384 × 2,
    /// the same 24 stood on end are 2 × 384. Rotation drives both the
    /// pixel order within a fixture and the direction the fixtures tile,
    /// because they are the same fact about how the thing is rigged.
    enum Rotation: Int, CaseIterable, Identifiable, Equatable {
        case none = 0
        case quarter = 90
        case half = 180
        case threeQuarter = 270

        var id: Int { rawValue }
        var label: String { "\(rawValue)°" }

        /// True when the fixture is on its end, so its pixels run down
        /// the screen and the fixtures stack rather than sit in a row.
        var isUpright: Bool { self == .quarter || self == .threeQuarter }
    }

    /// The space left between one fixture and the next.
    ///
    /// Fixtures in a rig are rarely butted together: a row of pixel lines
    /// might sit on 6-pixel centres with a dark gap between them, and the
    /// screen has to leave that room or everything downstream lands in the
    /// wrong place.
    ///
    /// Measured along the way the fixtures run rather than in screen X and
    /// Y, because which screen axis that is depends on the rotation: a
    /// line of fixtures spaces out sideways, the same fixtures stood on
    /// end space out downwards. Named axes meant turning the fixture
    /// turned a 6-pixel gap into a 6-pixel diagonal step.
    struct Gap: Equatable {
        /// Air between one fixture and the next, along the way they tile.
        var between: Int
        /// How far each fixture steps across that direction — zero for a
        /// straight row or a straight tower, more for one that climbs.
        var across: Int

        static let none = Gap(between: 0, across: 0)

        var isActive: Bool { between != 0 || across != 0 }
    }

    /// One fixture placed on the screen: its address, and where its block
    /// of pixels starts.
    struct Placement: Equatable {
        /// The fixture's own DMX address, absolute (universes in 512s).
        let address: Int
        /// Top-left cell of this fixture's block in the screen grid.
        let originX: Int
        let originY: Int
    }

    struct Pixel: Equatable {
        let x: Int
        let y: Int
        let universe: Int
        let channel: Int
    }

    /// The size one fixture's block occupies once it is turned.
    static func size(of block: Block, rotation: Rotation) -> (width: Int, height: Int) {
        rotation.isUpright ? (block.rows, block.columns) : (block.columns, block.rows)
    }

    /// Where a cell of the fixture's own grid lands once it is turned.
    ///
    /// Clockwise, so 90° puts the fixture's left-hand end at the top — the
    /// same way you would physically stand a line on its end.
    static func position(
        column: Int, row: Int, block: Block, rotation: Rotation
    ) -> (x: Int, y: Int) {
        switch rotation {
        case .none: return (column, row)
        case .quarter: return (block.rows - 1 - row, column)
        case .half: return (block.columns - 1 - column, block.rows - 1 - row)
        case .threeQuarter: return (row, block.columns - 1 - column)
        }
    }

    /// Lays the selected fixtures out in a line, or stacked if they are on
    /// their end.
    ///
    /// Side by side is what a row of pixel lines is: 24 lines of 16 make a
    /// screen 384 across. Turn them upright and the same 24 make a tower 2
    /// across and 384 high. The order is the caller's — the list the user
    /// ticked, in whatever order it is sorted — rather than anything
    /// inferred, so what comes out matches what they saw.
    static func placements(
        addresses: [Int], block: Block, rotation: Rotation = .none, gap: Gap = .none
    ) -> [Placement] {
        let size = size(of: block, rotation: rotation)
        // The pitch is the block plus the gap, along whichever way the
        // fixtures tile; the other axis only moves if they are staggered.
        let along = (rotation.isUpright ? size.height : size.width) + gap.between
        let pitchX = rotation.isUpright ? gap.across : along
        let pitchY = rotation.isUpright ? along : gap.across
        return addresses.enumerated().map { index, address in
            Placement(
                address: address,
                originX: index * pitchX,
                originY: index * pitchY)
        }
    }

    /// Every pixel, in reading order within each fixture.
    ///
    /// A pixel's channel is the fixture's address plus the offset, less one
    /// — the offset counts the fixture's own channels from 1, so a fixture
    /// at 1 with an offset of 6 lands on 6, not 7. Addresses are worked out
    /// absolutely and split at the end, so a block that runs off the end of
    /// a universe continues into the next one instead of reporting a
    /// channel above 512.
    static func pixels(
        placements: [Placement], block: Block, rotation: Rotation = .none
    ) -> [Pixel] {
        var pixels: [Pixel] = []
        pixels.reserveCapacity(placements.count * block.cellCount)

        for placement in placements {
            for row in 0..<block.rows {
                for column in 0..<block.columns {
                    guard let offset = block.offset(column: column, row: row) else { continue }
                    let absolute = placement.address + offset - 1
                    guard absolute >= 1 else { continue }
                    let split = MVRFixture.universeAndChannel(fromAbsoluteAddress: absolute)
                    let cell = position(column: column, row: row, block: block, rotation: rotation)
                    pixels.append(Pixel(
                        x: placement.originX + cell.x,
                        y: placement.originY + cell.y,
                        universe: split.universe,
                        channel: split.channel))
                }
            }
        }
        // Fixture by fixture, each in its own reading order — which is
        // how a real Disguise export is written. Sorting globally by y
        // then x looks tidier and is wrong: the reference file runs a
        // whole pixel line's two rows before starting the next line.
        return pixels
    }

    /// The whole screen's size, for the caller to show before exporting.
    static func screenSize(
        placements: [Placement], block: Block, rotation: Rotation
    ) -> (width: Int, height: Int) {
        let size = size(of: block, rotation: rotation)
        guard !placements.isEmpty else { return (0, 0) }
        // Taken over every fixture rather than the last one: with a
        // stagger the furthest right and the furthest down need not be
        // the same fixture, and neither need be the last.
        let width = placements.map { $0.originX + size.width }.max() ?? 0
        let height = placements.map { $0.originY + size.height }.max() ?? 0
        return (width, height)
    }

    /// The CSV Disguise reads: a header, then one line per pixel.
    static func csv(_ pixels: [Pixel]) -> String {
        var text = "x,y,universe,channel\n"
        for pixel in pixels {
            text += "\(pixel.x),\(pixel.y),\(pixel.universe),\(pixel.channel)\n"
        }
        return text
    }
}
