import Foundation

/// A contiguous run of Fixture IDs worth drawing cell-by-cell.
///
/// The map used to run from 0 to the highest ID in the file, which is fine
/// while IDs are dense but collapses as soon as one fixture sits high up —
/// consoles hand out IDs like 10001 or 500001, and a single fixture up
/// there meant rendering hundreds of thousands of empty cells. Splitting
/// into segments keeps the cost proportional to the IDs actually in use.
struct IDMapSegment: Identifiable {
    let start: Int
    let end: Int

    var id: Int { start }
    var count: Int { end - start + 1 }
}

/// One fixture sitting on one Fixture ID in a proposed patch.
struct IDMapOccupant {
    let name: String
    let spec: String
    /// Index within its type's groups, when this ID comes from the run.
    /// Nil for a fixture keeping the ID it already had.
    let groupIndex: Int?
    var isRenumbered: Bool { groupIndex != nil }
}

/// Shared by the Fixture ID Map and the Auto ID map preview, so the two
/// read alike — the same rows, the same collapsed gaps — and can't drift.
enum IDMapLayout {
    /// Every ID the finished patch would hold: what the run assigns, plus
    /// the IDs kept by types left out of it.
    ///
    /// The retained ones are the whole reason a collision can happen, so a
    /// map without them would show a clean run and hide the clash.
    ///
    /// Fixtures with no ID at all are counted, not placed. The main map
    /// files them under 0 — reasonable there, where 0 doubles as "none" —
    /// but here it stacks every unpatched fixture on one cell and paints it
    /// as a clash, which is the opposite of what this map is for: on one
    /// real file that invented 42 clashes against the run's true zero.
    static func occupancy(
        plan: AutoIDPlan,
        fixtures: [MVRFixture],
        includedTypes: Set<String>
    ) -> (slots: [Int: [IDMapOccupant]], unassigned: Int) {
        var slots: [Int: [IDMapOccupant]] = [:]
        var unassigned = 0

        for assignment in plan.assignments {
            slots[assignment.newID, default: []].append(IDMapOccupant(
                name: assignment.name,
                spec: assignment.spec,
                groupIndex: assignment.groupIndex))
        }

        for fixture in fixtures where !includedTypes.contains(fixture.gdtfSpec) {
            guard let id = fixture.currentFixtureID, id > 0 else {
                unassigned += 1
                continue
            }
            slots[id, default: []].append(IDMapOccupant(
                name: fixture.name,
                spec: fixture.gdtfSpec,
                groupIndex: nil))
        }

        return (slots, unassigned)
    }

    /// Groups the IDs in use into row-aligned runs, breaking wherever the
    /// empty stretch between them is too long to be worth drawing.
    ///
    /// Gaps are the point of this view, so the threshold is generous — a
    /// few rows of empty cells still render, and only genuinely huge jumps
    /// (a block at 1, another at 10001) collapse into a summary line.
    static func segments(usedIDs: [Int], columns: Int) -> [IDMapSegment] {
        let columns = max(1, columns)
        func rowStart(_ id: Int) -> Int { (id / columns) * columns }
        func rowEnd(_ id: Int) -> Int { rowStart(id) + columns - 1 }

        // Empty file: still show a small grid rather than nothing at all.
        guard let first = usedIDs.first else {
            return [IDMapSegment(start: 0, end: (2 * columns) - 1)]
        }

        let maximumGap = columns * 4
        var result: [IDMapSegment] = []
        var start = rowStart(first)
        var previous = first

        for id in usedIDs.dropFirst() {
            if id - previous > maximumGap {
                result.append(IDMapSegment(start: start, end: rowEnd(previous)))
                start = rowStart(id)
            }
            previous = id
        }
        result.append(IDMapSegment(start: start, end: rowEnd(previous)))
        return result
    }

    /// How many cells fit across, rounded down to a multiple of five so a
    /// row still starts on a readable number.
    static func columns(fittingWidth width: Double, cellSize: Double, spacing: Double) -> Int {
        let fitting = Int((width + spacing) / (cellSize + spacing))
        return max(5, (fitting / 5) * 5)
    }
}
