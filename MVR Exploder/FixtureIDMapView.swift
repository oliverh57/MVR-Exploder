import SwiftUI

/// A visual map of every Fixture ID slot, color-coded by GDTF type, so
/// gaps and clashes in the patch are easy to spot at a glance. Starts at
/// ID 0 (which doubles as "no ID assigned"), and scales its cell count to
/// the nearest power of 10 above the highest ID actually in use.
struct FixtureIDMapView: View {
    let fixtures: [MVRFixture]
    let onClose: () -> Void
    let onSelectID: (Int) -> Void

    // Precomputed once in init rather than as computed properties — with
    // thousands of cells, recalculating a Dictionary(grouping:) over every
    // fixture (and re-sorting the spec list) on every single cell's render
    // made the grid effectively unusable above a few hundred fixtures.
    private let fixturesByID: [Int: [MVRFixture]]
    private let sortedSpecs: [String]
    private let specColorIndex: [String: Int]
    private let totalCells: Int
    private let segments: [IDMapSegment]

    private let columns = 50
    private let cellSize: CGFloat = 18
    private let cellSpacing: CGFloat = 2

    init(fixtures: [MVRFixture], onClose: @escaping () -> Void, onSelectID: @escaping (Int) -> Void) {
        self.fixtures = fixtures
        self.onClose = onClose
        self.onSelectID = onSelectID

        self.fixturesByID = Dictionary(grouping: fixtures) { $0.currentFixtureID ?? 0 }

        let specs = Set(fixtures.map(\.gdtfSpec)).sorted()
        self.sortedSpecs = specs
        var indexMap: [String: Int] = [:]
        for (index, spec) in specs.enumerated() {
            indexMap[spec] = index
        }
        self.specColorIndex = indexMap

        self.segments = IDMapLayout.segments(
            usedIDs: fixturesByID.keys.sorted(),
            columns: columns)
        self.totalCells = segments.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            grid
            Divider()
            legend
        }
        .frame(width: 1060, height: 640)
    }

    private var header: some View {
        HStack {
            Text("Fixture ID Map")
                .font(.headline)
            Spacer()
            Text("\(fixturesByID.count) IDs used, \(totalCells.formatted()) slots shown")
                .foregroundStyle(.secondary)
            Button("Close", action: onClose)
        }
        .padding(12)
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    if index > 0 {
                        skippedRange(from: segments[index - 1].end, to: segment.start)
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: columns),
                        spacing: cellSpacing
                    ) {
                        ForEach(segment.start...segment.end, id: \.self) { id in
                            cell(for: id)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    /// Stands in for a stretch of unused IDs too large to draw.
    private func skippedRange(from previousEnd: Int, to nextStart: Int) -> some View {
        let skipped = nextStart - previousEnd - 1
        return HStack(spacing: 8) {
            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .frame(height: 1)
            Text("\(skipped.formatted()) unused IDs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private func cell(for id: Int) -> some View {
        let group = fixturesByID[id] ?? []
        let isClash = group.count > 1
        let primary = group.first

        return ZStack {
            Rectangle()
                .fill(primary.map { color(for: $0.gdtfSpec) } ?? Color.gray.opacity(0.06))
            Rectangle()
                .stroke(isClash ? Color.red : Color.gray.opacity(0.3), lineWidth: isClash ? 2 : 0.5)
            Text("\(id)")
                .font(.system(size: 8))
                .minimumScaleFactor(0.35)
                .lineLimit(1)
                .foregroundStyle(primary != nil ? Color.black.opacity(0.6) : Color.gray.opacity(0.7))
                .padding(.horizontal, 1)
        }
        .frame(width: cellSize, height: cellSize)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectID(id)
        }
        .help(tooltip(id: id, group: group, isClash: isClash))
    }

    private func tooltip(id: Int, group: [MVRFixture], isClash: Bool) -> String {
        if isClash {
            let names = group.map(\.name).joined(separator: ", ")
            return "Clashing Fixture ID \(id): \(names)"
        }
        if let fixture = group.first {
            return "\(id): \(fixture.name) (\(fixture.gdtfSpec))"
        }
        return "\(id): empty"
    }

    private var legend: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(sortedSpecs, id: \.self) { spec in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(for: spec))
                            .frame(width: 14, height: 14)
                        Text(spec)
                            .font(.caption)
                    }
                }
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.red, lineWidth: 2)
                        .frame(width: 14, height: 14)
                    Text("Clashing ID")
                        .font(.caption)
                }
            }
            .padding(12)
        }
    }

    /// Evenly-spaced hues around the color wheel, so any number of GDTF
    /// types get visually distinct colors rather than reusing a small
    /// fixed palette. O(1) lookup via the precomputed index map.
    private func color(for spec: String) -> Color {
        guard let index = specColorIndex[spec], !sortedSpecs.isEmpty else { return .gray }
        let hue = Double(index) / Double(sortedSpecs.count)
        return Color(hue: hue, saturation: 0.65, brightness: 0.85)
    }
}
