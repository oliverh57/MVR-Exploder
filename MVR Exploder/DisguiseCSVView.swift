import SwiftUI
import UniformTypeIdentifiers

/// Turns an MVR into the `x,y,universe,channel` CSV Disguise reads as a
/// DMX screen.
///
/// Four steps, because each one needs the answer to the last: open a file,
/// pick the fixture type the screen is made of, tick the fixtures that are
/// in it, then say how that fixture's pixels are laid out and which
/// channel drives each one.
///
/// The pixel layout is typed in rather than read from the GDTF. A GDTF can
/// describe it, but most files in the wild carry a stand-in that doesn't,
/// and the person doing the patch knows the answer anyway.
struct DisguiseCSVView: View {
    let onBack: () -> Void

    @StateObject private var document = MVRDocument()

    private enum Step: Int, CaseIterable {
        case file, type, fixtures, pixels

        var title: String {
            switch self {
            case .file: return "Open an MVR"
            case .type: return "Fixture type"
            case .fixtures: return "Fixtures"
            case .pixels: return "Pixel layout"
            }
        }
    }

    @State private var step: Step = .file
    @State private var isTargeted = false
    @State private var errorMessage: String?

    @State private var selectedSpec: String?
    @State private var selectedFixtureIDs: Set<String> = []
    /// The table's own row selection, which is not the tick: rows are
    /// selected to be acted on in bulk, ticked to go in the screen.
    @State private var rowSelection: Set<String> = []
    /// The table's own sort, which is also the order fixtures are laid out
    /// in while the order is coming from the table — so what you see in the
    /// list is what comes out in the file. Empty is the file's own order
    /// for the type, which is the default.
    @State private var sortOrder: [KeyPathComparator<MVRFixture>] = []
    @State private var layoutOrder = LayoutOrder.list
    /// Which way the numbers run when the order comes from position.
    @State private var strategy = AutoIDOrderStrategy.leftToRight
    /// Bumped whenever the order changes, which redraws the preview's
    /// arrows and replays them.
    @State private var orderRevision = 0

    /// Where the order of the fixtures on the screen comes from.
    private enum LayoutOrder: String, CaseIterable, Identifiable {
        /// The type's own list — the order the file gives them in, which
        /// is normally patch order — with the table's sort on top.
        case list
        /// Worked out from where the fixtures actually are, using the
        /// same ordering the Smart Auto ID run uses.
        case position

        var id: String { rawValue }
        var label: String { self == .list ? "Fixture order" : "Position (XYZ)" }
    }
    @State private var rotation = DisguisePixelMap.Rotation.none
    /// The space left between one fixture and the next, and whether it is
    /// being used at all. Off by default, because fixtures butted together
    /// is what a pixel line array usually is.
    @State private var showsGap = false
    @State private var gap = DisguisePixelMap.Gap.none

    @State private var block = DisguisePixelMap.Block(columns: 16, rows: 2)
    @State private var selectedCell: Int?
    @State private var offsetText = ""
    /// The pixel the suggested fill counts from, and the gap between
    /// pixels. Nil when there is nothing to suggest.
    @State private var fill: Fill?

    /// A proposed fill for every empty pixel, shown before it is applied.
    ///
    /// Typing an offset into all 32 pixels of a line is the same number
    /// over and over at a fixed gap, so the first one is enough to predict
    /// the rest. Shown rather than applied, because the gap is a guess
    /// until a second pixel confirms it — grey is the tool saying "this is
    /// what I think, not what I've done".
    private struct Fill: Equatable {
        var anchor: Int
        var value: Int
        var step: Int
    }
    @FocusState private var offsetFocused: Bool
    @State private var exportMessage: String?
    @State private var exportFailed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch step {
            case .file: filePicker
            case .type: typePicker
            case .fixtures: fixturePicker
            case .pixels: pixelEditor
            }

            Divider()
            footer
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Button("Back") { goBack() }
                .help(step == .file
                      ? "Back to the mode list."
                      : "Back to \(Step(rawValue: step.rawValue - 1)?.title ?? "").")

            Text("Disguise CSV Generator")
                .font(.headline)

            if !document.fileName.isEmpty {
                Text(document.fileName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // The steps double as navigation back to anything already done.
            HStack(spacing: 4) {
                ForEach(Step.allCases, id: \.rawValue) { candidate in
                    Button(candidate.title) { step = candidate }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(candidate == step ? Color.accentColor
                                         : (candidate.rawValue < step.rawValue ? .secondary : Color.secondary.opacity(0.4)))
                        .disabled(candidate.rawValue > step.rawValue)
                    if candidate != Step.allCases.last {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if let exportMessage {
                Text(exportMessage)
                    .foregroundStyle(exportFailed ? .red : .secondary)
            } else {
                Text(footerHint)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if step == .pixels {
                Text("\(grid.width) × \(grid.height) pixels  ·  \(pixelCount.formatted()) mapped")
                    .foregroundStyle(.secondary)
                Button("Export CSV…") { exportCSV() }
                    .buttonStyle(.borderedProminent)
                    .disabled(pixelCount == 0)
            } else {
                Button("Next") { advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
            }
        }
        .font(.caption)
        .padding(12)
    }

    private var footerHint: String {
        switch step {
        case .file: return "Drop an .mvr file here, or choose one."
        case .type: return "Which fixture type is the screen made of?"
        case .fixtures:
            return "\(selectedFixtureIDs.count) of \(fixturesOfType.count) ticked — "
                + (layoutOrder == .list
                   ? "laid out in the order listed here."
                   : "laid out by position, \(strategy.label.lowercased()).")
        case .pixels:
            return "Click a pixel and type the DMX offset from the fixture's own address."
        }
    }

    // MARK: - Step 1: the file

    private var filePicker: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Drop an MVR here")
                .font(.title3)
            Text("Or choose one — the fixtures and their DMX addresses come from it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose MVR…") { chooseFile() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
    }

    // MARK: - Step 2: the type

    private var typePicker: some View {
        List(typeSummaries, id: \.spec, selection: Binding(
            get: { selectedSpec },
            set: { selectedSpec = $0 })
        ) { summary in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                    Text("\(summary.count) fixtures  ·  \(summary.addresses)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .tag(summary.spec)
            .contentShape(Rectangle())
        }
        .listStyle(.inset)
    }

    private var typeSummaries: [(spec: String, name: String, count: Int, addresses: String)] {
        var bySpec: [String: [MVRFixture]] = [:]
        for fixture in document.fixtures { bySpec[fixture.gdtfSpec, default: []].append(fixture) }
        let names = GDTFSpecName.readableNames(for: Array(bySpec.keys))

        return bySpec
            .map { spec, fixtures in
                let patched = fixtures.compactMap(\.currentAddress).sorted()
                let addresses: String
                if let first = patched.first, let last = patched.last {
                    let low = MVRFixture.universeAndChannel(fromAbsoluteAddress: first)
                    let high = MVRFixture.universeAndChannel(fromAbsoluteAddress: last)
                    addresses = "U\(low.universe).\(low.channel) – U\(high.universe).\(high.channel)"
                } else {
                    addresses = "no addresses"
                }
                return (spec, names[spec] ?? spec, fixtures.count, addresses)
            }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    // MARK: - Step 3: the fixtures

    private var fixturePicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(selectedFixtureIDs.count == fixturesOfType.count ? "Untick all" : "Tick all") {
                    selectedFixtureIDs = selectedFixtureIDs.count == fixturesOfType.count
                        ? []
                        : Set(fixturesOfType.map(\.id))
                }

                Divider().frame(height: 14)

                Text("Order")
                Picker("", selection: $layoutOrder) {
                    ForEach(LayoutOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .help("Fixture order is the list this type comes in, which you "
                      + "can re-sort by clicking a column. Position works the "
                      + "order out from where the fixtures are.")

                if layoutOrder == .position {
                    Picker("", selection: $strategy) {
                        ForEach(AutoIDOrderStrategy.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 200)
                }

                if !rowSelection.isEmpty {
                    Divider().frame(height: 14)
                    Text("\(rowSelection.count) row\(rowSelection.count == 1 ? "" : "s") selected")
                        .foregroundStyle(.secondary)
                    Button("Tick") { setTicked(true, for: rowSelection) }
                    Button("Untick") { setTicked(false, for: rowSelection) }
                }

                Spacer()
            }
            .font(.caption)
            .padding(12)

            Divider()

            HStack(spacing: 0) {
            // The same table the other modes use — same columns, same
            // click-to-sort headers — with a tick column instead of the
            // inline editors, since nothing here changes the file.
            //
            // In position order the headers are left out of it: position
            // decides, and a sort that looked like it had changed the
            // layout but hadn't would be a lie.
            Table(fixturesOfType, selection: $rowSelection,
                  sortOrder: layoutOrder == .list ? $sortOrder : .constant([])) {
                TableColumn("") { fixture in
                    Toggle("", isOn: Binding(
                        get: { selectedFixtureIDs.contains(fixture.id) },
                        set: { on in
                            if on { selectedFixtureIDs.insert(fixture.id) }
                            else { selectedFixtureIDs.remove(fixture.id) }
                        }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                .width(28)

                // Where this fixture lands on the screen, 1 first. Only
                // the ticked ones have a place in it.
                TableColumn("#") { fixture in
                    Text(layoutPosition[fixture.id].map(String.init) ?? "–")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(34)

                TableColumn("Name", sortUsing: KeyPathComparator(\.name)) { fixture in
                    Text(fixture.name).lineLimit(1)
                }
                TableColumn("Fixture ID", sortUsing: KeyPathComparator(\.sortableFixtureID)) { fixture in
                    Text(fixture.currentFixtureID.map(String.init) ?? "-")
                }
                .width(80)
                TableColumn("Universe", sortUsing: KeyPathComparator(\.sortableUniverse)) { fixture in
                    Text(fixture.universe).monospacedDigit()
                }
                .width(70)
                TableColumn("Channel", sortUsing: KeyPathComparator(\.sortableChannel)) { fixture in
                    Text(fixture.channel).monospacedDigit()
                }
                .width(70)
                TableColumn("X", sortUsing: KeyPathComparator(\.sortableX)) { fixture in
                    Text(fixture.position3D.map { String(format: "%.2f m", $0.x / 1000) } ?? "-")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(80)
                TableColumn("Y", sortUsing: KeyPathComparator(\.sortableY)) { fixture in
                    Text(fixture.position3D.map { String(format: "%.2f m", $0.y / 1000) } ?? "-")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(80)
                TableColumn("Layer", sortUsing: KeyPathComparator(\.layerName)) { fixture in
                    Text(fixture.layerName).foregroundStyle(.secondary)
                }
            }
            // Shift-click a run, or Command-click a handful, then tick the
            // lot in one go. Right-clicking inside a selection acts on all
            // of it; right-clicking an unselected row acts on that row
            // alone — the same as the delete menu in the other tables.
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty {
                    Button(ids.count == 1
                           ? "Include in the Screen"
                           : "Include \(ids.count) Fixtures in the Screen") {
                        setTicked(true, for: ids)
                    }
                    Button(ids.count == 1
                           ? "Leave Out of the Screen"
                           : "Leave \(ids.count) Fixtures Out of the Screen") {
                        setTicked(false, for: ids)
                    }
                }
            }

            if layoutOrder == .position {
                Divider()
                orderPreview
                    .frame(width: 360)
            }
            }
        }
        .onChange(of: strategy) { _, _ in orderRevision += 1 }
        .onChange(of: layoutOrder) { _, _ in orderRevision += 1 }
        .onChange(of: selectedFixtureIDs) { _, _ in orderRevision += 1 }
    }

    /// The order as a picture: the same markers and direction arrows the
    /// Smart Auto ID preview draws, threaded through the ticked fixtures in
    /// the order they'll be laid out.
    private var orderPreview: some View {
        VStack(spacing: 0) {
            AutoIDPreviewView(
                fixtures: document.fixtures,
                focusedSpec: selectedSpec,
                overlays: [AutoIDGroupOverlay(
                    label: strategy.label,
                    color: .systemTeal,
                    fixtureIDs: orderedSelectedIDs)],
                focusedGroup: 0,
                selectedGroups: [0],
                revision: orderRevision,
                playToken: orderRevision,
                isSplitting: false,
                onSplit: { _, _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            Text(orderedSelectedIDs.count > 1
                 ? "The arrows run 1 → \(orderedSelectedIDs.count), which is the order "
                   + "the fixtures sit on the screen. Drag to orbit."
                 : "Tick some fixtures to see the order they'd be laid out in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Ticks or unticks a set of rows at once.
    private func setTicked(_ included: Bool, for ids: Set<String>) {
        if included {
            selectedFixtureIDs.formUnion(ids)
        } else {
            selectedFixtureIDs.subtract(ids)
        }
    }

    /// The fixtures of the chosen type, in the order they'll be laid out.
    ///
    /// Default is the order the file lists them in for this type, which is
    /// what a patch normally follows. Sorting a column re-orders them, and
    /// so does switching to position — in every case the list reads in the
    /// order the screen is built.
    private var fixturesOfType: [MVRFixture] {
        let ofType = document.fixtures.filter { $0.gdtfSpec == selectedSpec }
        switch layoutOrder {
        case .list:
            return ofType.sorted(using: sortOrder)
        case .position:
            return MVRAutoID.inOrder(fixtures: ofType, strategy: strategy)
        }
    }

    /// The ticked fixtures, in that same order — which is the order the
    /// CSV is written in.
    private var orderedSelectedIDs: [String] {
        fixturesOfType.filter { selectedFixtureIDs.contains($0.id) }.map(\.id)
    }

    /// Each ticked fixture's place on the screen, 1 first.
    private var layoutPosition: [String: Int] {
        var result: [String: Int] = [:]
        for (index, id) in orderedSelectedIDs.enumerated() { result[id] = index + 1 }
        return result
    }

    // MARK: - Step 4: the pixels

    private var pixelEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Stepper(value: Binding(
                    get: { block.columns },
                    set: { block.resize(columns: $0, rows: block.rows); fill = nil }),
                    in: 1...256
                ) {
                    Text("Across  \(block.columns)")
                }
                Stepper(value: Binding(
                    get: { block.rows },
                    set: { block.resize(columns: block.columns, rows: $0); fill = nil }),
                    in: 1...64
                ) {
                    Text("High  \(block.rows)")
                }

                Divider().frame(height: 18)

                Picker("", selection: $rotation) {
                    ForEach(DisguisePixelMap.Rotation.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: rotation) { _, _ in fill = nil }
                .help("Turn the fixture. A line on its end makes a tower, and the pixel "
                      + "coordinates follow.")

                Divider().frame(height: 18)

                gapControls

                Divider().frame(height: 18)

                if let selectedCell {
                    let column = selectedCell % block.columns
                    let row = selectedCell / block.columns
                    Text("Pixel \(selectedCell + 1)  ·  col \(column + 1), row \(row + 1)")
                    TextField("offset", text: $offsetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .focused($offsetFocused)
                        .onSubmit { commitOffset() }
                    Button("Set") { commitOffset() }
                    Button("Clear") {
                        block.setOffset(nil, column: column, row: row)
                        offsetText = ""
                    }
                } else {
                    Text("Click a pixel to give it a DMX offset.")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .font(.caption)
            .padding(12)

            if fill != nil, !suggestions.isEmpty {
                Divider()
                fillBar
            }

            Divider()

            Text("One \(selectedTypeName), turned \(rotation.label). Every selected "
                 + "fixture uses this layout. The big number is the pixel; under it "
                 + "the DMX offset you type, and the x,y it lands on."
                 + (showsGap
                    ? " The pale block is the next fixture along, showing the x,y "
                      + "its pixels land on."
                    : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            GeometryReader { proxy in
                // Shrink to fit rather than cut off: a turned line is a tall
                // tower, and the picture is only worth having if the whole
                // fixture is in it. Past the floor the cells stop shrinking
                // and it scrolls instead.
                let scale = gridScale(fitting: proxy.size)
                ScrollView([.horizontal, .vertical]) {
                    pixelGrid
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: gridSize.width * scale,
                               height: gridSize.height * scale,
                               alignment: .topLeading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private static let cellWidth: CGFloat = 46
    private static let cellHeight: CGFloat = 46
    private static let cellGap: CGFloat = 3

    /// Where the cells stop shrinking. Below this the numbers stop being
    /// readable, and scrolling is the better trade.
    private static let minimumGridScale: CGFloat = 0.5

    /// The grid at full size, before any fitting.
    private var gridSize: CGSize {
        let drawn = preview
        return CGSize(
            width: CGFloat(drawn.width) * Self.cellWidth
                 + CGFloat(max(0, drawn.width - 1)) * Self.cellGap,
            height: CGFloat(drawn.height) * Self.cellHeight
                 + CGFloat(max(0, drawn.height - 1)) * Self.cellGap)
    }

    /// How much to shrink the grid by to get all of it on screen.
    ///
    /// The room taken off allows for the padding either side and for the
    /// scroll bars, so a grid that only just fits isn't left sitting under
    /// one of them.
    private func gridScale(fitting available: CGSize) -> CGFloat {
        let size = gridSize
        guard size.width > 0, size.height > 0 else { return 1 }
        let room = CGSize(width: max(1, available.width - 48),
                          height: max(1, available.height - 36))
        let scale = min(room.width / size.width, room.height / size.height)
        return min(1, max(Self.minimumGridScale, scale))
    }

    /// The space between one fixture and the next.
    ///
    /// Shown as a tick and two numbers rather than two numbers alone: with
    /// it off the fixtures butt together, which is the common case, and
    /// the pale neighbour in the preview would be noise.
    private var gapControls: some View {
        HStack(spacing: 8) {
            // Turning it on starts at nothing, so the fixtures sit butted
            // together — the next one's first pixel lands at 6,0 on a
            // 6-wide block — and the gap is whatever you type. Starting it
            // at 1 to make the option visibly do something read as an
            // off-by-one in the coordinates, which matter more.
            Toggle("Gap between fixtures", isOn: $showsGap)
                .toggleStyle(.checkbox)

            if showsGap {
                // The arrows say which way each number pushes at this
                // rotation, so a gap set on a row still reads as a gap
                // once the fixtures are stood on end.
                Image(systemName: rotation.isUpright ? "arrow.down" : "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { gap.between },
                    set: { gap.between = max(0, $0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .help("Pixels of air between one fixture and the next.")

                Text("stagger")
                    .foregroundStyle(.secondary)
                Image(systemName: rotation.isUpright ? "arrow.right" : "arrow.down")
                    .foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { gap.across },
                    set: { gap.across = max(0, $0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .help("How far each fixture steps sideways from the one "
                          + "before it. Zero keeps the row — or the tower — straight.")
            }
        }
        .help("Pixels left between one fixture and the next, measured along the "
              + "way they run: sideways for a row, downwards once they are stood "
              + "on end.")
    }

    /// The offer to fill the rest in, with the gap it would use.
    private var fillBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.accentColor)

            Text("Fill the other \(suggestions.count) pixels, counting up in")

            TextField("", value: Binding(
                get: { fill?.step ?? 3 },
                set: { fill?.step = max(1, $0) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)

            Text("from \(fill?.value ?? 0)")

            Button("Use these") { applySuggestions() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button("No thanks") { fill = nil }
                .controlSize(.small)

            Spacer()

            Text("Shown in grey below until you accept.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.07))
    }

    /// One fixture's pixels, drawn as the grid they are.
    ///
    /// Only one fixture's worth: every fixture of a type shares the layout,
    /// so drawing all 24 would be the same picture 24 times.
    private var pixelGrid: some View {
        // Drawn the way round the fixture is hung, so turning it shows the
        // tower rather than describing one.
        let preview = self.preview
        return VStack(spacing: Self.cellGap) {
            ForEach(0..<preview.height, id: \.self) { y in
                HStack(spacing: Self.cellGap) {
                    ForEach(0..<preview.width, id: \.self) { x in
                        if let cell = preview.cells[y * preview.width + x] {
                            pixelCell(
                                column: cell.column, row: cell.row,
                                x: x, y: y, ghost: cell.fixture > 0)
                        } else {
                            Color.clear
                                .frame(width: Self.cellWidth, height: Self.cellHeight)
                        }
                    }
                }
            }
        }
    }

    private struct PreviewCell {
        /// 0 is the fixture being edited; anything higher is a neighbour
        /// drawn only to show the gap.
        let fixture: Int
        let column: Int
        let row: Int
    }

    /// What the grid draws: one fixture, and — once a gap is being set —
    /// a pale copy of the one after it with that gap between them.
    ///
    /// Built as a lookup rather than asked cell by cell, because with two
    /// fixtures on screen the question is asked for every square of the
    /// bounding box and the answer is the same walk each time.
    private var preview: (width: Int, height: Int, cells: [Int: PreviewCell]) {
        let size = DisguisePixelMap.size(of: block, rotation: rotation)
        let placements = self.placements
        // The neighbour only exists if there is one to show.
        let shown = showsGap && placements.count > 1
            ? Array(placements.prefix(2))
            : Array(placements.prefix(1))
        let origins = shown.isEmpty
            ? [(x: 0, y: 0)]
            : shown.map { (x: $0.originX, y: $0.originY) }

        let width = origins.map { $0.x + size.width }.max() ?? size.width
        let height = origins.map { $0.y + size.height }.max() ?? size.height

        var cells: [Int: PreviewCell] = [:]
        cells.reserveCapacity(origins.count * block.cellCount)
        for (index, origin) in origins.enumerated() {
            for row in 0..<block.rows {
                for column in 0..<block.columns {
                    let at = DisguisePixelMap.position(
                        column: column, row: row, block: block, rotation: rotation)
                    let x = origin.x + at.x
                    let y = origin.y + at.y
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    // The fixture being edited wins any square the
                    // neighbour would otherwise land on, which only
                    // happens at a gap small enough to overlap.
                    let key = y * width + x
                    if cells[key] == nil || index == 0 {
                        cells[key] = PreviewCell(fixture: index, column: column, row: row)
                    }
                }
            }
        }
        return (width, height, cells)
    }

    private func pixelCell(
        column: Int, row: Int, x: Int, y: Int, ghost: Bool = false
    ) -> some View {
        let index = row * block.columns + column
        let offset = block.offset(column: column, row: row)
        let suggested = offset == nil ? suggestions[index] : nil
        let isSelected = !ghost && selectedCell == index

        return Button {
            selectedCell = index
            offsetText = offset.map(String.init) ?? ""
            offsetFocused = true
        } label: {
            VStack(spacing: 0) {
                if ghost {
                    // The neighbour repeats this fixture's pixels and its
                    // offsets exactly — the only thing that differs is
                    // where they land, so that is all it shows.
                    Text("\(x),\(y)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    // Which pixel this is, counted the way the offsets
                    // run. The number you look for first, so the one that
                    // leads.
                    Text("\(index + 1)")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(offset.map(String.init) ?? suggested.map(String.init) ?? "–")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        // Grey, and lighter still than the secondary label
                        // colour: a suggested number has to be legible
                        // enough to check and plainly not a number anyone
                        // typed.
                        .foregroundStyle(offset == nil
                                         ? Color.secondary.opacity(suggested == nil ? 0.3 : 0.55)
                                         : .secondary)
                    // The coordinate the pixel lands on. Not editable — it
                    // follows from where the fixture is in the row and
                    // which way round it is hung — but worth seeing,
                    // because it is what the CSV says.
                    Text("\(x),\(y)")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Self.cellWidth, height: Self.cellHeight)
            .background(
                offset == nil ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.28),
                in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        // The neighbour is there to show the gap, not to be typed into:
        // every fixture shares one layout, so editing it would mean
        // editing the fixture next to it.
        .opacity(ghost ? 0.3 : 1)
        .disabled(ghost)
        .help(ghost ? "The next fixture along, \(gap.between) pixels on." : "")
    }

    private var selectedTypeName: String {
        guard let selectedSpec else { return "fixture" }
        return GDTFSpecName.readable(selectedSpec)
    }

    /// The suggested value for each empty pixel, keyed by cell index.
    private var suggestions: [Int: Int] {
        guard let fill else { return [:] }
        return block.suggestions(anchor: fill.anchor, value: fill.value, step: fill.step)
    }

    private func applySuggestions() {
        for (index, value) in suggestions {
            block.setOffset(value, column: index % block.columns, row: index / block.columns)
        }
        fill = nil
    }

    // MARK: - Derived

    private var placements: [DisguisePixelMap.Placement] {
        let addresses = fixturesOfType
            .filter { selectedFixtureIDs.contains($0.id) }
            .compactMap(\.currentAddress)
        return DisguisePixelMap.placements(
            addresses: addresses, block: block, rotation: rotation,
            gap: showsGap ? gap : .none)
    }

    private var pixelCount: Int {
        placements.count * block.filledCount
    }

    private var grid: (width: Int, height: Int) {
        DisguisePixelMap.screenSize(placements: placements, block: block, rotation: rotation)
    }

    // MARK: - Actions

    private var canAdvance: Bool {
        switch step {
        case .file: return !document.fixtures.isEmpty
        case .type: return selectedSpec != nil
        case .fixtures: return !selectedFixtureIDs.isEmpty
        case .pixels: return false
        }
    }

    /// One step back, and out to the mode list only from the first —
    /// the steps are a sequence, so Back ought to walk it.
    private func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) {
            step = previous
        } else {
            onBack()
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        if step == .type {
            selectedFixtureIDs = Set(fixturesOfType.map(\.id))
            rowSelection = []
        }
        step = next
    }

    private func commitOffset() {
        guard let selectedCell else { return }
        let column = selectedCell % block.columns
        let row = selectedCell / block.columns
        let trimmed = offsetText.trimmingCharacters(in: .whitespaces)
        let typed = trimmed.isEmpty ? nil : Int(trimmed)
        block.setOffset(typed, column: column, row: row)

        // Offer to do the rest. The gap comes from the pixels already
        // filled in once there are two to compare, and is a plain RGB
        // pixel until then — either way it is editable in the bar.
        if let typed {
            fill = Fill(anchor: selectedCell, value: typed, step: block.inferredStep())
        }

        // Straight on to the next pixel, because the job is typing a
        // number into every one of them in turn.
        let next = selectedCell + 1
        if next < block.cellCount {
            self.selectedCell = next
            offsetText = block.offset(column: next % block.columns, row: next / block.columns)
                .map(String.init) ?? ""
            offsetFocused = true
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mvr")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "mvr" else {
                DispatchQueue.main.async { errorMessage = "Please drop a valid .mvr file." }
                return
            }
            DispatchQueue.main.async { load(url) }
        }
        return true
    }

    private func load(_ url: URL) {
        do {
            // Whichever field holds the ID doesn't matter here — the CSV is
            // built from DMX addresses, not fixture IDs — so this never
            // stops to ask.
            try document.load(from: url, idFieldName: "FixtureID")
            errorMessage = nil
            selectedSpec = nil
            selectedFixtureIDs = []
            rowSelection = []
            step = .type
        } catch {
            errorMessage = "Couldn't read that MVR: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        let pixels = DisguisePixelMap.pixels(placements: placements, block: block, rotation: rotation)
        guard !pixels.isEmpty else { return }

        let panel = NSSavePanel()
        let base = document.fileName.isEmpty
            ? "Pixel Map"
            : (document.fileName as NSString).deletingPathExtension
        panel.prepareForExport(named: "\(base) Pixel Map.csv", fileExtension: "csv")
        panel.canCreateDirectories = true
        panel.title = "Export Disguise CSV"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try DisguisePixelMap.csv(pixels)
                .write(to: url.ensuringPathExtension("csv"), atomically: true, encoding: .utf8)
            exportFailed = false
            exportMessage = "Exported \(pixels.count.formatted()) pixels, "
                + "\(grid.width) × \(grid.height)."
        } catch {
            exportFailed = true
            exportMessage = error.localizedDescription
        }
    }
}
