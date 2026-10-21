import SwiftUI
import UniformTypeIdentifiers

/// The Fixture ID map's counterpart for the patch: every DMX universe in
/// use, channel by channel, with each fixture filling as many channels as
/// its mode takes — so free space, overlaps and how full each universe is
/// show at a glance. Fixtures are clicked to edit and dragged to move, as
/// on the ID map.
struct DMXUniverseMapView: View {
    let document: MVRDocument
    let onClose: () -> Void

    /// Channel counts by GDTF spec, nil until read. A fixture's width is
    /// only in its GDTF, and a map drawn before then would show every
    /// fixture one channel wide and the rig half empty.
    @State private var footprints: [String: [GDTFFootprint]]?

    var body: some View {
        Group {
            if let footprints {
                DMXUniverseMap(document: document, footprints: footprints, onClose: onClose)
            } else {
                VStack(spacing: 0) {
                    ToolHeader("DMX Universe Map", onBack: onClose)
                    Divider()
                    ProgressView("Reading channel counts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { footprints = await document.loadFootprints() }
    }

    /// An absolute address the way a patch reads it: universe.channel.
    nonisolated static func label(_ address: Int) -> String {
        "\((address - 1) / 512 + 1).\((address - 1) % 512 + 1)"
    }
}

/// The map itself, once the channel counts are in.
///
/// Built for size: a rig is tens of universes of 512 channels, and every
/// one of them is a cell. The rows only draw — each one a single canvas —
/// and everything that can be done to a cell is handled once, for the
/// whole map, by working out which cell is under the pointer. A view per
/// cell, each with its own tooltip, drag, drop, menu and popover, took
/// seconds to scroll a page, and got slower the further it went, as every
/// row ever drawn kept its handlers registered.
struct DMXUniverseMap: View {
    let document: MVRDocument
    let fixtures: [MVRFixture]
    let onClose: () -> Void

    /// The fixtures picked, by id. Click picks one cell's; Shift-click
    /// adds or takes one away.
    @State private var selection: Set<String> = []
    /// The cell the editor hangs from: the last one clicked.
    @State private var editingAddress: Int?
    /// Whether the editor is on a selection (edit together) or one cell's
    /// fixtures (one at a time, which is what an overlap needs).
    @State private var editsTogether = false
    /// The cell a drag is over, lit so it's clear where the drop lands.
    @State private var dropTarget: Int?
    /// Why the last drag didn't move anything.
    @State private var moveProblem: String?
    /// What the pointer is over. Kept out of the map's own state, so moving
    /// the mouse redraws only the handle that follows it.
    @State private var hover = MapHover()
    /// Universes picked in the strip along the top. Click picks one;
    /// Shift-click adds or takes one away.
    @State private var pickedUniverses: Set<Int> = []
    /// The universe move being asked about, while its dialog is open.
    @State private var universeMove: UniverseMove?
    /// What's typed into that dialog.
    @State private var universeEntry = ""
    /// The universe to bring into view.
    @State private var scrollRequest: ScrollRequest?

    // Precomputed once in init: there are 512 cells a universe, and each
    // one looks itself up here.
    /// Channels each patched fixture takes, by fixture id. Missing when
    /// its type has no usable count, and then drawn one channel wide.
    private let widths: [String: Int]
    /// Which fixtures sit on each channel, by absolute address: indices
    /// into `fixtures`, earliest first.
    private let occupants: [Int: [Int]]
    /// Fixtures that run past channel 512, by index.
    private let overruns: Set<Int>
    /// Each fixture's colour, and the darker shade of it its later
    /// channels take — so two fixtures of one type side by side still
    /// read as two.
    private let shades: [(first: Color, rest: Color)]
    /// Every universe with something in it, sorted.
    private let universes: [Int]
    private let channelsUsed: [Int: Int]
    /// Each universe in miniature, for the strip along the top.
    private let universeRuns: [Int: [UniverseChip.Run]]
    /// Universes with an overlap, or a fixture running past 512.
    private let troubledUniverses: Set<Int>
    private let unknownWidthTypes: [String]
    private let unpatchedCount: Int
    private let types: FixtureTypeKey

    private let cellSpacing: CGFloat = 3
    private let widestCell: CGFloat = 44
    private let cellHeight: CGFloat = 24

    init(document: MVRDocument, footprints: [String: [GDTFFootprint]], onClose: @escaping () -> Void) {
        self.document = document
        let fixtures = document.fixtures
        self.fixtures = fixtures
        self.onClose = onClose
        let types = FixtureTypeKey(fixtures: fixtures)
        self.types = types

        let patched = fixtures.indices.filter { !fixtures[$0].hasNoDMXPatch }
        self.unpatchedCount = fixtures.count - patched.count

        // Patch Check's reading of the footprints: a type whose GDTF gives
        // no count, or a count the rig's own spacing contradicts, gets no
        // width rather than a wrong one.
        let placed = MVRPatchCheck.placements(fixtures: patched.map { fixtures[$0] }, footprints: footprints)
        let widths = Dictionary(uniqueKeysWithValues: placed.patches.map { ($0.fixtureID, $0.footprint) })
        self.widths = widths
        self.unknownWidthTypes = placed.unknownTypes.union(placed.suspectTypes.map(\.spec)).sorted()

        let shades = fixtures.map {
            (first: types.color(for: $0.gdtfSpec), rest: types.color(for: $0.gdtfSpec, brightness: 0.5))
        }
        self.shades = shades

        var occupants: [Int: [Int]] = [:]
        var overruns: Set<Int> = []
        var runs: [Int: [UniverseChip.Run]] = [:]
        var troubled: Set<Int> = []
        for index in patched.sorted(by: { fixtures[$0].sortableAddress < fixtures[$1].sortableAddress }) {
            guard let start = fixtures[index].currentAddress else { continue }
            let universe = MVRFixture.universeAndChannel(fromAbsoluteAddress: start).universe
            let universeEnd = universe * 512
            let end = start + (widths[fixtures[index].id] ?? 1) - 1
            if end > universeEnd {
                overruns.insert(index)
                troubled.insert(universe)
            }
            for address in start...min(end, universeEnd) {
                occupants[address, default: []].append(index)
            }
            runs[universe, default: []].append(UniverseChip.Run(
                channels: (start - 1) % 512 + 1...(min(end, universeEnd) - 1) % 512 + 1,
                color: shades[index].first))
        }
        self.occupants = occupants
        self.overruns = overruns
        self.universeRuns = runs

        var used: [Int: Int] = [:]
        for (address, group) in occupants {
            let universe = MVRFixture.universeAndChannel(fromAbsoluteAddress: address).universe
            used[universe, default: 0] += 1
            if group.count > 1 { troubled.insert(universe) }
        }
        self.channelsUsed = used
        self.troubledUniverses = troubled
        self.universes = used.keys.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                grid
                Divider()
                FixtureTypeLegend(types: types) { legendFooter }
                    .frame(width: FixtureIDMapView.legendWidth)
            }
        }
        .frame(minWidth: FixtureIDMapView.minimumWidth, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    private var header: some View {
        ToolHeader("DMX Universe Map", onBack: onClose) {
            Spacer()
            if let moveProblem {
                Text(moveProblem)
                    .foregroundStyle(.red)
            } else if selection.count > 1 {
                Text("\(selection.count) selected — drag one to move them all")
                    .foregroundStyle(.secondary)
            } else if pickedUniverses.count > 1 {
                Text("\(pickedUniverses.count) universes picked — right-click one to move them")
                    .foregroundStyle(.secondary)
            } else {
                Text(summary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        var text = "\(universes.count) universe\(universes.count == 1 ? "" : "s") used"
        if unpatchedCount > 0 { text += ", \(unpatchedCount) unpatched" }
        return text + " — drag a cell to move it"
    }

    private var grid: some View {
        GeometryReader { space in
            // Sized as the ID map's are, so the two read alike: rows of
            // 50, 25, 20 or 10 starting from channel 1.
            let available = space.size.width - 24
            let columns = FixtureIDMapView.columnCount(for: available, spacing: cellSpacing)
            let fitted = (available - CGFloat(columns - 1) * cellSpacing) / CGFloat(columns)
            let layout = DMXMapLayout(
                universes: universes, columns: columns, size: min(widestCell, fitted.rounded(.down)),
                spacing: cellSpacing, cellHeight: cellHeight)

            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if !universes.isEmpty {
                        universeStrip(width: layout.rowWidth)
                        Divider()
                    }
                    channels(layout)
                }
                .onChange(of: scrollRequest) { _, request in
                    // Its heading, at the top.
                    if let request { proxy.scrollTo(-2 * request.universe, anchor: .top) }
                }
            }
        }
        .alert(
            universeMove?.title ?? "",
            isPresented: Binding(get: { universeMove != nil }, set: { if !$0 { universeMove = nil } }),
            presenting: universeMove
        ) { move in
            TextField(move.kind == .to ? "Universe" : "Universes", text: $universeEntry)
            Button(move.kind == .to ? "Move" : "Offset") { perform(move) }
            Button("Cancel", role: .cancel) {}
        } message: { move in
            Text(move.message)
        }
    }

    /// Every universe's channels, scrolling.
    private func channels(_ layout: DMXMapLayout) -> some View {
        ScrollView(.vertical) {
            if universes.isEmpty {
                Text("No fixtures are patched.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(layout.lines) { line in
                    switch line.kind {
                    case let .gap(first, last):
                        skippedUniverses(from: first, to: last)
                            .frame(width: layout.rowWidth, height: DMXMapLayout.gapHeight, alignment: .bottom)
                    case let .heading(universe):
                        universeHeading(universe)
                            .frame(height: DMXMapLayout.headingHeight, alignment: .bottomLeading)
                    case let .cells(start, count):
                        row(from: start, count: count, layout: layout)
                            .frame(height: layout.rowHeight, alignment: .top)
                    }
                }
            }
            // As wide as a row and no wider, so a point on it is measured
            // from the first cell.
            .frame(width: layout.rowWidth)
            .overlay(alignment: .topLeading) {
                HoverHandle(hover: hover, layout: layout, tooltip: tooltip(for:), dragLabel: dragLabel(from:))
            }
            .background {
                // Remade when the editor moves to another cell, so it
                // closes and reopens there rather than staying put.
                let shown = editingAddress
                Color.clear
                    .popover(
                        isPresented: Binding(
                            get: { shown != nil },
                            set: { if !$0, let shown { dismissEditor(at: shown) } }),
                        attachmentAnchor: .rect(.rect(layout.rect(of: shown ?? 1))),
                        arrowEdge: .bottom
                    ) {
                        editor
                    }
                    .id(shown)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let address = layout.address(at: location)
                    guard address != hover.address else { return }
                    hover.address = address
                    let run = address.flatMap { run(at: $0, columns: layout.columns) }
                    if run != hover.run { hover.run = run }
                case .ended:
                    hover.address = nil
                    hover.run = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                guard let address = layout.address(at: location) else { return }
                let group = group(at: address)
                if NSEvent.modifierFlags.contains(.shift) {
                    toggle(group, at: address)
                } else {
                    pick(group, at: address)
                }
            }
            .onDrop(of: [.plainText], delegate: ChannelDrop(
                layout: layout, target: $dropTarget,
                move: { _ = move(from: $0, to: $1) }))
            // From the left, not centred: in line with the strip above,
            // whether or not a scroll bar is taking up room on the right.
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // One menu for the whole map: it only ever acts on the
        // selection.
        .contextMenu { typeFilterMenu }
    }

    // MARK: - Universes

    /// Every universe in use along the top, each a picture of what's in
    /// it: click one to go to it, Shift-click to pick several, right-click
    /// to move them. Up to three rows, then it scrolls. As wide as the
    /// rows of channels below it, so the two line up.
    private func universeStrip(width: CGFloat) -> some View {
        let spacing: CGFloat = 4
        let perRow = max(1, Int((width + spacing) / (UniverseChip.minimumWidth + spacing)))
        let rows = min(3, (universes.count + perRow - 1) / perRow)
        return ScrollView(.vertical) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: perRow),
                spacing: spacing
            ) {
                ForEach(universes, id: \.self) { universe in
                    UniverseChip(
                        universe: universe,
                        runs: universeRuns[universe] ?? [],
                        isPicked: pickedUniverses.contains(universe),
                        hasProblem: troubledUniverses.contains(universe))
                        .equatable()
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.shift) {
                                if pickedUniverses.remove(universe) == nil { pickedUniverses.insert(universe) }
                            } else {
                                pickedUniverses = [universe]
                                scrollRequest = ScrollRequest(universe: universe)
                            }
                        }
                        // Fixed labels, and the universes worked out when
                        // one is chosen: a chip that hasn't redrawn since
                        // the picking changed would otherwise act on the
                        // old picks.
                        .contextMenu {
                            Button("Move to Universe…") { ask(.to, from: universe) }
                            Button("Offset by…") { ask(.offset, from: universe) }
                        }
                        .help("Universe \(universe): \(channelsUsed[universe] ?? 0) of 512 channels used"
                              + (troubledUniverses.contains(universe) ? ", with overlaps" : ""))
                }
            }
            .frame(width: width)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: CGFloat(rows) * UniverseChip.height + CGFloat(rows - 1) * spacing)
        .padding(.vertical, 10)
    }

    /// Opens the dialog for a move. A universe right-clicked outside the
    /// picks is moved on its own, and becomes the pick — as in Finder.
    private func ask(_ kind: UniverseMove.Kind, from universe: Int) {
        if !pickedUniverses.contains(universe) { pickedUniverses = [universe] }
        universeEntry = ""
        universeMove = UniverseMove(kind: kind, universes: pickedUniverses.sorted())
    }

    private func perform(_ move: UniverseMove) {
        let entry = universeEntry.trimmingCharacters(in: .whitespaces)
        guard let number = Int(entry) else {
            moveProblem = "Not moved: \"\(entry)\" isn't a whole number."
            return
        }
        let picked = Set(move.universes)
        let plan = move.kind == .to
            ? DMXMapMove.plan(universes: picked, to: number, in: fixtures, widths: widths)
            : DMXMapMove.plan(universes: picked, offsetBy: number, in: fixtures, widths: widths)
        switch plan {
        case .blocked(let reason):
            moveProblem = reason
        case .moves(let moves):
            moveProblem = nil
            guard !moves.isEmpty else { return }
            closeEditor()
            hover.run = nil
            hover.address = nil
            document.setAddresses(moves)
            // The picks follow the universes to where they went.
            let landed = move.kind == .to
                ? Array(number..<(number + move.universes.count))
                : move.universes.map { $0 + number }
            pickedUniverses = Set(landed)
            scrollRequest = ScrollRequest(universe: landed.min() ?? number)
        }
    }

    private func universeHeading(_ universe: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "Universe \(universe)")
                .font(.subheadline.weight(.semibold))
            Text(verbatim: "\(channelsUsed[universe] ?? 0) of 512 channels used")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    /// Stands in for universes with nothing in them.
    private func skippedUniverses(from first: Int, to last: Int) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .frame(height: 1)
            Text(verbatim: first == last ? "Universe \(first) unused" : "Universes \(first)–\(last) unused")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .frame(height: 1)
        }
    }

    private func row(from start: Int, count: Int, layout: DMXMapLayout) -> some View {
        let range = start..<(start + count)
        return ChannelRow(
            start: start,
            cells: range.map(cell(at:)),
            dropColumn: dropTarget.flatMap { range.contains($0) ? $0 - start : nil },
            size: layout.size,
            spacing: layout.spacing,
            height: cellHeight)
            .equatable()
    }

    private func cell(at address: Int) -> ChannelRow.Cell {
        guard let group = occupants[address], let first = group.first else { return ChannelRow.Cell() }
        let isStart = group.contains { fixtures[$0].currentAddress == address }
        return ChannelRow.Cell(
            fill: isStart ? shades[first].first : shades[first].rest,
            isStart: isStart,
            isClash: group.count > 1 || group.contains(where: overruns.contains),
            isSelected: group.allSatisfy { selection.contains(fixtures[$0].id) })
    }

    private func group(at address: Int) -> [MVRFixture] {
        (occupants[address] ?? []).map { fixtures[$0] }
    }

    /// The channels either side of `address`, within its row, that hold
    /// exactly the same fixtures — one fixture, usually, or the stretch
    /// two of them share. They get one tooltip and one drag handle.
    private func run(at address: Int, columns: Int) -> MapHover.Run? {
        guard let group = occupants[address] else { return nil }
        let channel = (address - 1) % 512
        let rowStart = address - channel % columns
        let rowEnd = min(rowStart + columns, address - channel + 512)
        var first = address
        while first > rowStart, occupants[first - 1] == group { first -= 1 }
        var last = address
        while last + 1 < rowEnd, occupants[last + 1] == group { last += 1 }
        return MapHover.Run(start: first, count: last - first + 1)
    }

    private var editor: some View {
        FixtureEditor(
            document: document,
            fixtureIDs: editsTogether ? orderedSelection : editingAddress.map { group(at: $0).map(\.id) } ?? [],
            scope: editsTogether ? .together : .each
        ) {
            closeEditor()
        }
        // A new editor when the selection changes, so its fields reload
        // rather than showing the last set's values.
        .id(selection)
    }

    /// Closes the editor if it's still on this cell — not if it has just
    /// moved to another one, which also closes this cell's popover.
    private func dismissEditor(at address: Int) {
        if editingAddress == address { closeEditor() }
    }

    // MARK: - Moving

    /// What a drag from this cell carries: its fixtures, unless it's part
    /// of a bigger selection, which then moves as one.
    private func movingFixtures(from address: Int) -> [MVRFixture] {
        let group = group(at: address)
        let ids = Set(group.map(\.id))
        if !ids.isEmpty, ids.isSubset(of: selection), selection.count > ids.count {
            return fixtures.filter { selection.contains($0.id) }
        }
        // An overlap gives up its later fixture, so dragging it off clears
        // the overlap rather than moving both somewhere else.
        if group.count > 1, let last = group.last { return [last] }
        return group
    }

    private func dragLabel(from address: Int) -> String {
        let moving = movingFixtures(from: address)
        return moving.count > 1
            ? "\(moving.count) fixtures"
            : moving.first?.currentAddress.map(DMXUniverseMapView.label) ?? ""
    }

    private func move(from source: Int, to target: Int) -> Bool {
        dropTarget = nil
        let moving = movingFixtures(from: source)
        switch DMXMapMove.plan(moving: Set(moving.map(\.id)), from: source, to: target,
                               in: fixtures, widths: widths) {
        case .blocked(let reason):
            moveProblem = reason
            return false
        case .moves(let moves):
            moveProblem = nil
            editingAddress = nil
            // What was under the pointer has just moved away from it.
            hover.run = nil
            hover.address = nil
            document.setAddresses(moves)
            return !moves.isEmpty
        }
    }

    // MARK: - Selection

    private func pick(_ group: [MVRFixture], at address: Int) {
        moveProblem = nil
        guard !group.isEmpty else {
            closeEditor()
            return
        }
        selection = Set(group.map(\.id))
        editsTogether = false
        editingAddress = address
    }

    private func toggle(_ group: [MVRFixture], at address: Int) {
        guard !group.isEmpty else { return }
        let ids = Set(group.map(\.id))
        if ids.isSubset(of: selection) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
        editsTogether = true
        editingAddress = selection.isEmpty ? nil : address
    }

    private func closeEditor() {
        editingAddress = nil
        selection = []
    }

    /// The selection in patch order, which is the order a bulk renumber
    /// uses.
    private var orderedSelection: [String] {
        fixtures
            .filter { selection.contains($0.id) }
            .sorted { $0.sortableAddress < $1.sortableAddress }
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

    private func tooltip(for run: MapHover.Run) -> String {
        let group = occupants[run.start] ?? []
        let lines = group.map { index in
            let fixture = fixtures[index]
            var line = "\(fixture.name) — \(types.label(for: fixture.gdtfSpec)), \(span(of: fixture))"
            if overruns.contains(index) { line += ", runs past 512" }
            return line
        }
        guard group.count > 1 else { return lines.first ?? "" }
        let shared = DMXUniverseMapView.label(run.start)
            + (run.count > 1 ? "–" + DMXUniverseMapView.label(run.start + run.count - 1) : "")
        return "\(shared) is used by \(group.count) fixtures:\n" + lines.joined(separator: "\n")
    }

    private func span(of fixture: MVRFixture) -> String {
        guard let start = fixture.currentAddress else { return "" }
        guard let width = widths[fixture.id] else {
            return "at \(DMXUniverseMapView.label(start)), width unknown"
        }
        return "\(DMXUniverseMapView.label(start))–\(DMXUniverseMapView.label(start + width - 1)) (\(width) ch)"
    }

    @ViewBuilder
    private var legendFooter: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.red, lineWidth: 2)
                .frame(width: 14, height: 14)
            Text("Overlapping, or past 512")
                .font(.caption)
        }
        if !unknownWidthTypes.isEmpty {
            // Said plainly, so a type drawn one channel wide isn't read as
            // a one-channel fixture with free space after it.
            Text("Drawn one channel wide — the GDTF has no channel count that fits the patch:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(unknownWidthTypes, id: \.self) { spec in
                Text(types.label(for: spec))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A universe move waiting on its number.
private struct UniverseMove {
    enum Kind {
        /// The lowest goes to the number given, the rest straight after.
        case to
        /// All of them up or down by the number given.
        case offset
    }

    let kind: Kind
    /// Sorted.
    let universes: [Int]

    var title: String {
        let verb = kind == .to ? "Move" : "Offset"
        if universes.count == 1 { return "\(verb) Universe \(universes[0])" }
        if universes.count > 6 { return "\(verb) \(universes.count) Universes" }
        return "\(verb) Universes " + universes.map(String.init).formatted(.list(type: .and))
    }

    var message: String {
        switch kind {
        case .to where universes.count == 1:
            return "Enter the universe to move it to. Every fixture keeps its channel."
        case .to:
            return "Enter the universe for the first of them. The rest follow straight after, "
                + "in order, and every fixture keeps its channel."
        case .offset:
            return "Enter how many universes to move by — a negative number moves them down. "
                + "Every fixture keeps its channel."
        }
    }
}

/// Asks the map to bring a universe into view. A new one each time, so
/// asking for the same universe again still scrolls back to it.
private struct ScrollRequest: Equatable {
    let universe: Int
    private let id = UUID()

    init(universe: Int) { self.universe = universe }
}

/// One universe in the strip along the top: its number, and its 512
/// channels squeezed into a bar, each fixture in its colour — so a full
/// universe, a nearly empty one and one with room at the end all look
/// different at a glance.
private struct UniverseChip: View, Equatable {
    struct Run: Equatable {
        /// 1–512.
        let channels: ClosedRange<Int>
        let color: Color
    }

    static let minimumWidth: CGFloat = 52
    static let height: CGFloat = 34

    let universe: Int
    let runs: [Run]
    let isPicked: Bool
    let hasProblem: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        VStack(spacing: 4) {
            Text(verbatim: String(universe))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.12)))
                for run in runs {
                    let x = CGFloat(run.channels.lowerBound - 1) / 512 * size.width
                    let width = max(1, CGFloat(run.channels.count) / 512 * size.width)
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                                 with: .color(run.color))
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(isPicked ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05), in: shape)
        .overlay {
            if isPicked { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
        }
        .overlay(alignment: .topTrailing) {
            if hasProblem {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .padding(4)
            }
        }
        .contentShape(shape)
    }
}

/// Where everything sits on the map, so a point can be turned into a cell
/// and a cell into a rectangle without asking the views. Every line has a
/// fixed height for that reason.
struct DMXMapLayout {
    struct Line: Identifiable {
        enum Kind {
            case gap(Int, Int)
            case heading(Int)
            case cells(start: Int, count: Int)
        }

        let id: Int
        let kind: Kind
    }

    static let headingHeight: CGFloat = 34
    static let gapHeight: CGFloat = 26

    let columns: Int
    /// A cell's width.
    let size: CGFloat
    let spacing: CGFloat
    let cellHeight: CGFloat
    /// The map top to bottom: each universe's heading and rows of cells,
    /// with a line standing in for any empty universes between.
    let lines: [Line]
    /// Where each line starts.
    let tops: [CGFloat]
    /// The line each universe's first row of cells is on.
    let firstRow: [Int: Int]

    var pitch: CGFloat { size + spacing }
    var rowHeight: CGFloat { cellHeight + spacing }
    var rowWidth: CGFloat { CGFloat(columns) * pitch - spacing }

    init(universes: [Int], columns: Int, size: CGFloat, spacing: CGFloat, cellHeight: CGFloat) {
        self.columns = columns
        self.size = size
        self.spacing = spacing
        self.cellHeight = cellHeight

        var lines: [Line] = []
        var tops: [CGFloat] = []
        var firstRow: [Int: Int] = [:]
        var y: CGFloat = 0
        func add(_ line: Line, height: CGFloat) {
            lines.append(line)
            tops.append(y)
            y += height
        }
        for (index, universe) in universes.enumerated() {
            if index > 0, universe - universes[index - 1] > 1 {
                add(Line(id: -2 * universe - 1, kind: .gap(universes[index - 1] + 1, universe - 1)),
                    height: Self.gapHeight)
            }
            add(Line(id: -2 * universe, kind: .heading(universe)), height: Self.headingHeight)
            firstRow[universe] = lines.count
            let first = (universe - 1) * 512 + 1
            for start in stride(from: first, to: first + 512, by: columns) {
                add(Line(id: start, kind: .cells(start: start, count: min(columns, first + 512 - start))),
                    height: cellHeight + spacing)
            }
        }
        self.lines = lines
        self.tops = tops
        self.firstRow = firstRow
    }

    /// The channel at a point on the map, if it's on one.
    func address(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        // The last line starting at or above the point.
        var low = 0
        var high = tops.count
        while low < high {
            let middle = (low + high) / 2
            if tops[middle] <= point.y { low = middle + 1 } else { high = middle }
        }
        let line = low - 1
        guard line >= 0, case let .cells(start, count) = lines[line].kind,
              point.y - tops[line] < cellHeight else { return nil }
        let column = Int(point.x / pitch)
        return column < count ? start + column : nil
    }

    /// Where a run of channels sits on the map. They're expected to be in
    /// one row.
    func rect(of address: Int, count: Int = 1) -> CGRect {
        let channel = (address - 1) % 512
        guard let first = firstRow[(address - 1) / 512 + 1] else { return .zero }
        let line = first + channel / columns
        return CGRect(x: CGFloat(channel % columns) * pitch, y: tops[line],
                      width: CGFloat(count) * pitch - spacing, height: cellHeight)
    }
}

/// What the pointer is over on the map.
@Observable
private final class MapHover {
    struct Run: Equatable {
        let start: Int
        let count: Int
    }

    /// The channel under the pointer. Not observed: it changes with every
    /// cell crossed, and only a drag starting needs it, at that moment.
    @ObservationIgnored var address: Int?
    /// The fixture, or shared stretch of fixtures, under the pointer.
    var run: Run?
}

/// The one tooltip and drag handle on the map, laid over whichever fixture
/// the pointer is on.
private struct HoverHandle: View {
    let hover: MapHover
    let layout: DMXMapLayout
    let tooltip: (MapHover.Run) -> String
    let dragLabel: (Int) -> String

    var body: some View {
        if let run = hover.run {
            let rect = layout.rect(of: run.start, count: run.count)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: rect.width, height: rect.height)
                .help(tooltip(run))
                // The channel it was picked up by, so a fixture grabbed by
                // its fifth channel lands with that channel on the drop.
                .draggable(String(hover.address ?? run.start)) {
                    DragPreview(label: { dragLabel(hover.address ?? run.start) })
                }
                .position(x: rect.midX, y: rect.midY)
                // A new handle for each fixture, so each gets its own
                // tooltip rather than keeping the last one's.
                .id(run.start)
        }
    }
}

/// A fixture dropped on the map, and the channel a drag is over on the way.
/// A DropDelegate rather than dropDestination's drop session, which needs
/// macOS 26: this reports where the drag is on macOS 15 too.
private struct ChannelDrop: DropDelegate {
    let layout: DMXMapLayout
    @Binding var target: Int?
    let move: (Int, Int) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let address = layout.address(at: info.location)
        if target != address { target = address }
        return nil
    }

    func dropExited(info: DropInfo) {
        target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard let destination = layout.address(at: info.location),
              let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadTransferable(type: String.self) { result in
            guard let source = (try? result.get()).flatMap({ Int($0) }) else { return }
            DispatchQueue.main.async { move(source, destination) }
        }
        return true
    }
}

/// One row of channel cells, drawn in one go.
///
/// Compared by value, so a change on the map — a drag passing over, a
/// click in another universe — redraws only the rows it touches.
private struct ChannelRow: View, Equatable {
    struct Cell: Equatable {
        /// Nil for a free channel.
        var fill: Color?
        var isStart = false
        var isClash = false
        var isSelected = false
    }

    let start: Int
    let cells: [Cell]
    let dropColumn: Int?
    let size: CGFloat
    let spacing: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { context, _ in
            for (column, cell) in cells.enumerated() {
                let rect = CGRect(x: CGFloat(column) * (size + spacing), y: 0, width: size, height: height)
                draw(cell, channel: (start + column - 1) % 512 + 1, isDropTarget: dropColumn == column,
                     in: rect, on: &context)
            }
        }
        .frame(width: CGFloat(cells.count) * (size + spacing) - spacing, height: height)
    }

    private func draw(_ cell: Cell, channel: Int, isDropTarget: Bool, in rect: CGRect,
                      on context: inout GraphicsContext) {
        let shape = Path(roundedRect: rect, cornerRadius: 4, style: .continuous)
        if let fill = cell.fill {
            context.fill(shape, with: .color(fill))
        } else {
            context.fill(shape, with: .color(.primary.opacity(0.035)))
            outline(rect, .primary.opacity(0.08), width: 1, on: &context)
        }
        if cell.isClash { outline(rect, .red, width: 2, on: &context) }
        if cell.isSelected { outline(rect, .white, width: 2, on: &context) }
        if isDropTarget { outline(rect, .accentColor, width: 3, on: &context) }

        let label = Text(verbatim: String(channel))
            .font(.system(size: 11, weight: cell.isStart ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(cell.fill == nil
                             ? Color.secondary.opacity(0.55)
                             : Color.white.opacity(cell.isStart ? 0.95 : 0.75))
        context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// A line just inside the cell's edge, so neighbouring rows don't cut
    /// it off.
    private func outline(_ rect: CGRect, _ color: Color, width: CGFloat, on context: inout GraphicsContext) {
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        context.stroke(Path(roundedRect: inset, cornerRadius: 4 - width / 2, style: .continuous),
                       with: .color(color), lineWidth: width)
    }
}

/// What follows the pointer on a drag. The label is worked out only when a
/// drag starts.
private struct DragPreview: View {
    let label: () -> String

    var body: some View {
        Text(verbatim: label())
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Where fixtures go when cells are dragged round the universe map.
enum DMXMapMove: Equatable {
    /// New absolute address by fixture id.
    case moves([String: Int])
    case blocked(String)

    /// Moves `moving` by the distance from `source` to `target`, keeping
    /// their spacing — so a fixture grabbed by its fifth channel and
    /// dropped on 105 starts at 101. Unlike the ID map nothing is swapped,
    /// since two fixtures rarely take the same number of channels: a move
    /// only lands in free channels, and never runs a fixture past 512.
    ///
    /// `widths` is channels by fixture id; a fixture without one counts
    /// as one channel, the same as the map draws it.
    static func plan(moving ids: Set<String>, from source: Int, to target: Int,
                     in fixtures: [MVRFixture], widths: [String: Int]) -> DMXMapMove {
        let delta = target - source
        guard delta != 0, !ids.isEmpty else { return .moves([:]) }

        func span(_ fixture: MVRFixture, from start: Int) -> ClosedRange<Int> {
            start...(start + (widths[fixture.id] ?? 1) - 1)
        }

        var moves: [String: Int] = [:]
        for fixture in fixtures where ids.contains(fixture.id) {
            guard let address = fixture.currentAddress, address > 0 else { continue }
            let moved = span(fixture, from: address + delta)
            guard moved.lowerBound >= 1 else { return .blocked("DMX addresses start at 1.") }
            if MVRFixture.universeAndChannel(fromAbsoluteAddress: moved.lowerBound).universe
                != MVRFixture.universeAndChannel(fromAbsoluteAddress: moved.upperBound).universe {
                return .blocked("Not moved: \(fixture.name) would run past channel 512.")
            }
            moves[fixture.id] = moved.lowerBound
        }
        return clear(moves, in: fixtures, widths: widths)
    }

    /// Moves whole universes so the lowest lands on `first` and the rest
    /// follow on after it in order, closing up any gaps between them.
    static func plan(universes: Set<Int>, to first: Int,
                     in fixtures: [MVRFixture], widths: [String: Int]) -> DMXMapMove {
        let mapping = Dictionary(uniqueKeysWithValues: universes.sorted().enumerated().map { ($1, first + $0) })
        return plan(universeMapping: mapping, in: fixtures, widths: widths)
    }

    /// Moves whole universes up or down by `offset`, keeping the gaps
    /// between them.
    static func plan(universes: Set<Int>, offsetBy offset: Int,
                     in fixtures: [MVRFixture], widths: [String: Int]) -> DMXMapMove {
        let mapping = Dictionary(uniqueKeysWithValues: universes.map { ($0, $0 + offset) })
        return plan(universeMapping: mapping, in: fixtures, widths: widths)
    }

    /// Every fixture in a universe goes to the same channel in its new
    /// one, so nothing can newly run past 512 — the only question is
    /// whether the channels it lands on are free.
    private static func plan(universeMapping mapping: [Int: Int],
                             in fixtures: [MVRFixture], widths: [String: Int]) -> DMXMapMove {
        guard mapping.values.allSatisfy({ $0 >= 1 }) else { return .blocked("Universes start at 1.") }
        var moves: [String: Int] = [:]
        for fixture in fixtures {
            guard let address = fixture.currentAddress, address > 0 else { continue }
            let universe = (address - 1) / 512 + 1
            guard let target = mapping[universe], target != universe else { continue }
            moves[fixture.id] = address + (target - universe) * 512
        }
        return clear(moves, in: fixtures, widths: widths)
    }

    /// The moves, unless one lands on a fixture that isn't moving itself.
    private static func clear(_ moves: [String: Int], in fixtures: [MVRFixture],
                              widths: [String: Int]) -> DMXMapMove {
        func span(_ id: String, from start: Int) -> ClosedRange<Int> {
            start...(start + (widths[id] ?? 1) - 1)
        }
        let landing = moves.map { span($0.key, from: $0.value) }
        let inTheWay = fixtures.compactMap { fixture -> Int? in
            guard moves[fixture.id] == nil, let address = fixture.currentAddress, address > 0
            else { return nil }
            let taken = span(fixture.id, from: address)
            return landing.contains { $0.overlaps(taken) } ? address : nil
        }.sorted()
        if inTheWay.isEmpty { return .moves(moves) }

        let list = inTheWay.prefix(3).map(DMXUniverseMapView.label).joined(separator: ", ")
            + (inTheWay.count > 3 ? " and \(inTheWay.count - 3) more" : "")
        return .blocked("Not moved: \(list) \(inTheWay.count == 1 ? "is" : "are") in the way.")
    }
}
