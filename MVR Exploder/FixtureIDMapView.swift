import SwiftUI

/// A visual map of every Fixture ID slot, color-coded by GDTF type, so
/// gaps and clashes in the patch are easy to spot at a glance. Starts at
/// ID 0 (which doubles as "no ID assigned"), and scales its cell count to
/// the nearest power of 10 above the highest ID actually in use.
struct FixtureIDMapView: View {
    let document: MVRDocument
    let fixtures: [MVRFixture]
    let onClose: () -> Void

    /// The fixtures picked, by id. Click picks one cell's; Shift-click
    /// adds or takes one away.
    @State private var selection: Set<String> = []
    /// The cell the editor hangs from: the last one clicked.
    @State private var editingID: Int?
    /// Whether the editor is on a selection (edit together) or one cell's
    /// fixtures (one at a time, which is what a clash needs).
    @State private var editsTogether = false
    /// The cell a drag is over, lit so it's clear where the drop lands.
    @State private var dropTarget: Int?
    /// Why the last drag didn't move anything.
    @State private var moveProblem: String?

    // Precomputed once in init rather than as computed properties — with
    // thousands of cells, recalculating a Dictionary(grouping:) over every
    // fixture (and re-sorting the spec list) on every single cell's render
    // made the grid effectively unusable above a few hundred fixtures.
    private let fixturesByID: [Int: [MVRFixture]]
    private let types: FixtureTypeKey
    /// Every ID in use, sorted, which the rows are laid out from.
    private let usedIDs: [Int]

    static let legendWidth: CGFloat = 230
    /// Fifty of the smallest cells, their gaps and padding, and the key.
    /// Ten readable cells and the key.
    static let minimumWidth: CGFloat = 900

    private let cellSpacing: CGFloat = 3
    /// Cells are wider than they're tall: wide enough for a five-digit ID
    /// at a readable size, and short, so a screen of them reads as a patch
    /// rather than a wall of blocks. Square cells had to choose between
    /// numbers too small to read and blocks too big to take in.
    private static let narrowestCell: CGFloat = 30
    private let widestCell: CGFloat = 44
    private let cellHeight: CGFloat = 24

    init(document: MVRDocument, onClose: @escaping () -> Void) {
        self.document = document
        let fixtures = document.fixtures
        self.fixtures = fixtures
        self.onClose = onClose

        self.fixturesByID = Dictionary(grouping: fixtures) { $0.currentFixtureID ?? 0 }
        self.types = FixtureTypeKey(fixtures: fixtures)
        self.usedIDs = fixturesByID.keys.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                grid
                Divider()
                FixtureTypeLegend(types: types) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.red, lineWidth: 2)
                            .frame(width: 14, height: 14)
                        Text("Clashing ID")
                            .font(.caption)
                    }
                }
                .frame(width: Self.legendWidth)
            }
        }
        // Fifty cells across and the key beside them set the width; the
        // height is the window's.
        .frame(minWidth: Self.minimumWidth, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    private var header: some View {
        ToolHeader("Fixture ID Map", onBack: onClose) {
            Spacer()
            if let moveProblem {
                Text(moveProblem)
                    .foregroundStyle(.red)
            } else {
                Text(selection.count > 1
                     ? "\(selection.count) selected — drag one to move them all"
                     : "\(fixturesByID.count) IDs used — drag a cell to move it")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var grid: some View {
        GeometryReader { space in
            // As big as the window allows, so the numbers are readable in
            // a big window instead of a small grid floating in the middle.
            // As many across as still leaves every cell readable: 50 on a
            // very wide window, 25 or 20 on an ordinary one, 10 at worst.
            // Rows start on round numbers either way, so it reads like a
            // patch sheet.
            let available = space.size.width - 24
            let columns = Self.columnCount(for: available, spacing: cellSpacing)
            let fitted = (available - CGFloat(columns - 1) * cellSpacing) / CGFloat(columns)
            let size = min(widestCell, fitted.rounded(.down))
            let segments = IDMapLayout.segments(usedIDs: usedIDs, columns: columns)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        if index > 0 {
                            skippedRange(from: segments[index - 1].end, to: segment.start)
                        }
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(size), spacing: cellSpacing), count: columns),
                            spacing: cellSpacing
                        ) {
                            ForEach(segment.start...segment.end, id: \.self) { id in
                                cell(for: id, size: size)
                            }
                        }
                    }
                }
                .padding(12)
                // Centred when the cells have stopped growing and the
                // window is still wider.
                .frame(maxWidth: .infinity)
            }
        }
    }

    static func columnCount(for width: CGFloat, spacing: CGFloat) -> Int {
        for count in [50, 25, 20, 10] {
            let cell = (width - CGFloat(count - 1) * spacing) / CGFloat(count)
            if cell >= narrowestCell { return count }
        }
        return 10
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

    private func cell(for id: Int, size: CGFloat) -> some View {
        let group = fixturesByID[id] ?? []
        let isClash = group.count > 1
        let primary = group.first

        let isSelected = !group.isEmpty && group.allSatisfy { selection.contains($0.id) }

        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)

        return ZStack {
            shape.fill(primary.map { types.color(for: $0.gdtfSpec) } ?? Color.primary.opacity(0.035))
            if primary == nil {
                shape.stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            if isClash {
                shape.stroke(Color.red, lineWidth: 2)
            }
            if isSelected {
                shape.stroke(Color.white, lineWidth: 2)
            }
            if dropTarget == id {
                shape.stroke(Color.accentColor, lineWidth: 3)
            }
            // Verbatim, so 9001 isn't printed as "9,001" — the separator
            // took a quarter of a cell's width and made every number in
            // the map harder to read.
            Text(verbatim: String(id))
                .font(.system(size: 11, weight: primary != nil ? .medium : .regular).monospacedDigit())
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .foregroundStyle(primary != nil ? Color.white.opacity(0.95) : Color.secondary.opacity(0.55))
                .padding(.horizontal, 2)
        }
        .frame(width: size, height: cellHeight)
        .contentShape(Rectangle())
        .modifier(MovableCell(
            payload: primary == nil ? nil : String(id),
            preview: dragPreview(for: id, group: group)))
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, let source = Int(item) else { return false }
            return move(from: source, to: id)
        } isTargeted: { over in
            if over {
                dropTarget = id
            } else if dropTarget == id {
                dropTarget = nil
            }
        }
        // Edited where it was spotted, rather than off in the table: a used
        // cell opens its fixture — both of them, on a clash. Shift-click
        // builds a selection and edits it all together.
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                toggle(group, at: id)
            } else {
                pick(group, at: id)
            }
        }
        .contextMenu { typeFilterMenu }
        .help(tooltip(id: id, group: group, isClash: isClash))
        .popover(isPresented: Binding(
            get: { editingID == id },
            set: { if !$0, editingID == id { closeEditor() } }),
            arrowEdge: .bottom) {
            FixtureEditor(
                document: document,
                fixtureIDs: editsTogether ? orderedSelection : group.map(\.id),
                scope: editsTogether ? .together : .each
            ) {
                closeEditor()
            }
            // A new editor when the selection changes, so its fields
            // reload rather than showing the last set's values.
            .id(selection)
        }
    }

    // MARK: - Moving

    /// What a drag from this cell carries: its fixtures, unless it's part
    /// of a bigger selection, which then moves as one.
    private func movingFixtures(from id: Int) -> [MVRFixture] {
        let group = fixturesByID[id] ?? []
        let ids = Set(group.map(\.id))
        if !ids.isEmpty, ids.isSubset(of: selection), selection.count > ids.count {
            return fixtures.filter { selection.contains($0.id) }
        }
        // A clash gives up one of its fixtures, so dragging it off clears
        // the clash rather than moving it somewhere else.
        if group.count > 1, let last = group.last { return [last] }
        return group
    }

    private func dragPreview(for id: Int, group: [MVRFixture]) -> some View {
        let count = movingFixtures(from: id).count
        return Text(verbatim: count > 1 ? "\(count) fixtures" : String(id))
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(group.first.map { types.color(for: $0.gdtfSpec) } ?? .gray,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func move(from source: Int, to target: Int) -> Bool {
        dropTarget = nil
        let moving = movingFixtures(from: source)
        switch IDMapMove.plan(moving: Set(moving.map(\.id)), from: source, to: target, in: fixtures) {
        case .blocked(let reason):
            moveProblem = reason
            return false
        case .moves(let moves):
            moveProblem = nil
            editingID = nil
            document.setFixtureIDs(moves)
            return !moves.isEmpty
        }
    }

    // MARK: - Selection

    private func pick(_ group: [MVRFixture], at id: Int) {
        moveProblem = nil
        guard !group.isEmpty else {
            closeEditor()
            return
        }
        selection = Set(group.map(\.id))
        editsTogether = false
        editingID = id
    }

    private func toggle(_ group: [MVRFixture], at id: Int) {
        guard !group.isEmpty else { return }
        let ids = Set(group.map(\.id))
        if ids.isSubset(of: selection) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
        editsTogether = true
        editingID = selection.isEmpty ? nil : id
    }

    private func closeEditor() {
        editingID = nil
        selection = []
    }

    /// The selection in ID order, which is the order a bulk renumber uses.
    private var orderedSelection: [String] {
        fixtures
            .filter { selection.contains($0.id) }
            .sorted { ($0.currentFixtureID ?? .max) < ($1.currentFixtureID ?? .max) }
            .map(\.id)
    }

    /// Narrows the selection to one type.
    @ViewBuilder
    private var typeFilterMenu: some View {
        let picked = fixtures.filter { selection.contains($0.id) }
        let bySpec = Dictionary(grouping: picked, by: \.gdtfSpec)
        if bySpec.count > 1 {
            ForEach(bySpec.keys.sorted(), id: \.self) { spec in
                Button("Only \(types.label(for: spec)) (\(bySpec[spec]?.count ?? 0))") {
                    selection = Set((bySpec[spec] ?? []).map(\.id))
                    editsTogether = selection.count > 1
                }
            }
            Divider()
        }
        if !selection.isEmpty {
            Button("Clear Selection") { closeEditor() }
        }
    }

    private func tooltip(id: Int, group: [MVRFixture], isClash: Bool) -> String {
        if isClash {
            let names = group.map(\.name).joined(separator: ", ")
            return "\(id) is used twice: \(names)"
        }
        if let fixture = group.first {
            return "\(id): \(fixture.name) — \(types.label(for: fixture.gdtfSpec))"
        }
        return "\(id): free"
    }
}

/// Lets a used cell be picked up; a free one has nothing to carry.
private struct MovableCell<Preview: View>: ViewModifier {
    let payload: String?
    let preview: Preview

    func body(content: Content) -> some View {
        if let payload {
            content.draggable(payload) { preview }
        } else {
            content
        }
    }
}

/// Where fixtures go when cells are dragged round the ID map.
enum IDMapMove: Equatable {
    /// New Fixture ID by fixture id.
    case moves([String: Int])
    case blocked(String)

    /// Moves `moving` by the distance from `source` to `target`, keeping
    /// their spacing. One cell dropped on another swaps the two; a
    /// selection only moves into free IDs, so nothing is pushed out of
    /// the way that wasn't asked about.
    static func plan(moving ids: Set<String>, from source: Int, to target: Int,
                     in fixtures: [MVRFixture]) -> IDMapMove {
        let delta = target - source
        guard delta != 0, !ids.isEmpty else { return .moves([:]) }

        let moving = fixtures.filter { ids.contains($0.id) }
        var moves: [String: Int] = [:]
        for fixture in moving {
            moves[fixture.id] = (fixture.currentFixtureID ?? 0) + delta
        }
        if let lowest = moves.values.min(), lowest < 1 {
            return .blocked("Fixture IDs start at 1.")
        }

        let destinations = Set(moves.values)
        let inTheWay = fixtures.filter {
            !ids.contains($0.id) && destinations.contains($0.currentFixtureID ?? 0)
        }
        if inTheWay.isEmpty { return .moves(moves) }

        let isOneCell = Set(moving.map { $0.currentFixtureID ?? 0 }).count == 1
        if isOneCell, source >= 1 {
            for fixture in inTheWay { moves[fixture.id] = source }
            return .moves(moves)
        }
        let taken = Set(inTheWay.compactMap(\.currentFixtureID)).sorted()
        let list = taken.prefix(3).map(String.init).joined(separator: ", ")
            + (taken.count > 3 ? " and \(taken.count - 3) more" : "")
        return .blocked("Not moved: \(list) \(taken.count == 1 ? "is" : "are") taken.")
    }
}
