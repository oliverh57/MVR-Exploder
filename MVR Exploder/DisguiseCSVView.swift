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
    /// The table's own sort, which is also the order the fixtures are laid
    /// out in — so what you see in the list is what comes out in the file.
    /// Empty is the file's own order for the type, which is the default.
    @State private var sortOrder: [KeyPathComparator<MVRFixture>] = []
    /// Bumped whenever the order or the ticks change, which recolours the
    /// preview.
    @State private var orderRevision = 0
    /// Bumped to run the fixtures through in order as a run of flashes.
    /// Separate from the revision so replaying doesn't rebuild the scene
    /// or move a camera the user has just set.
    @State private var playToken = 0
    @State private var playTask: Task<Void, Never>?
    /// How wide the preview pane is, and the width it had when a drag on
    /// the splitter started.
    @State private var previewWidth: CGFloat = 360
    @State private var dragStartWidth: CGFloat?
    /// The same, for the CSV beside the pixel grid.
    @State private var csvWidth: CGFloat = 250
    @State private var csvDragStart: CGFloat?
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
    /// The fixture under the cursor in the pixel view, as an index into
    /// the laid-out fixtures.
    @State private var hoveredFixture: Int?
    /// The pixel under the cursor, and where the cursor is, so the
    /// readout can follow it.
    @State private var hoveredPixel: HoveredPixel?
    /// The fixture whose pixel was clicked, which is where the card
    /// stays while the cursor wanders off over the others.
    @State private var cardFixture = 0
    /// The part of the grid on screen, in grid coordinates. Everything
    /// outside it is skipped by the drawing.
    @State private var visibleRect: CGRect = .zero
    /// Set while the "clear everything" question is on screen.
    @State private var isClearing = false

    /// What a pixel is, in the three terms the CSV is written in.
    private struct HoveredPixel: Equatable {
        let coordinate: String
        let address: String
        let number: Int
        let unit: String
        let fixtureAddress: String
        /// Top-left of the pixel being described, so the card sits beside
        /// it and holds still while the cursor moves within it.
        let anchor: CGPoint
    }
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
                + "laid out in the order listed here."
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
                Text("Sort a column to change the order they're laid out in. "
                     + "Select rows and tick any one of them to tick them all.")
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .font(.caption)
            .padding(12)

            Divider()

            HStack(spacing: 0) {
            // The same table the other modes use — same columns, same
            // click-to-sort headers — with a tick column instead of the
            // inline editors, since nothing here changes the file.
            Table(fixturesOfType, selection: $rowSelection, sortOrder: $sortOrder) {
                TableColumn("") { fixture in
                    Toggle("", isOn: Binding(
                        get: { selectedFixtureIDs.contains(fixture.id) },
                        set: { on in
                            // A row that is part of a selection brings the
                            // rest with it, so a run of fixtures is ticked
                            // from the box already under the cursor. A row
                            // outside the selection answers for itself.
                            setTicked(on, for: rowSelection.contains(fixture.id)
                                      ? rowSelection : [fixture.id])
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

            previewSplitter

            selectionPreview
                .frame(width: previewWidth)
            }
        }
        .confirmationDialog(
            "Clear the pixel layout?",
            isPresented: $isClearing,
            titleVisibility: .visible
        ) {
            Button("Clear Everything", role: .destructive) { clearLayout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every offset you've typed goes, along with the rotation, the "
                 + "pixel direction, the starting corner and the gap. The block "
                 + "stays the size it is, and the fixtures stay ticked.")
        }
        .onChange(of: selectedFixtureIDs) { _, _ in orderRevision += 1; schedulePlay() }
        .onChange(of: sortOrder) { _, _ in orderRevision += 1; schedulePlay() }
        // Arriving at the step plays the order once, so the picture is
        // already answering "which way round does this go" before anyone
        // asks it.
        .onAppear { schedulePlay() }
    }

    /// The handle between the table and the preview.
    private var previewSplitter: some View {
        splitter(width: $previewWidth, startWidth: $dragStartWidth)
    }

    /// A draggable edge for a pane on the right of something.
    private func splitter(width: Binding<CGFloat>, startWidth: Binding<CGFloat?>) -> some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = startWidth.wrappedValue ?? width.wrappedValue
                                startWidth.wrappedValue = start
                                width.wrappedValue = min(900, max(180, start - value.translation.width))
                            }
                            .onEnded { _ in startWidth.wrappedValue = nil }))
    }

    /// Replays the order, after a pause.
    ///
    /// Ticking a run of fixtures fires a change per row, and replaying on
    /// each one would strobe the whole type — waiting for the clicking to
    /// stop gives one clean run instead.
    private func schedulePlay() {
        playTask?.cancel()
        playTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            playToken += 1
        }
    }

    /// What is going on the screen, as a picture: the fixtures of this
    /// type in 3D, the ticked ones coloured and the rest left grey, with
    /// the path threaded through them in the order they'll be laid out.
    private var selectionPreview: some View {
        VStack(spacing: 0) {
            AutoIDPreviewView(
                // Only this type: the rest of the rig was drawn faded as
                // context, and on a show file that context is thousands of
                // fixtures nobody is choosing between.
                fixtures: fixturesOfType,
                focusedSpec: selectedSpec,
                overlays: [AutoIDGroupOverlay(
                    label: "On the screen",
                    color: .systemTeal,
                    fixtureIDs: orderedSelectedIDs)],
                focusedGroup: 0,
                selectedGroups: [0],
                revision: orderRevision,
                playToken: playToken,
                isSplitting: false,
                onSplit: { _, _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Text(orderedSelectedIDs.isEmpty
                     ? "Nothing ticked yet — every fixture of this type is grey."
                     : "Coloured fixtures are on the screen, grey ones are left "
                       + "out. Drag to orbit, Shift-drag to pan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    playToken += 1
                } label: {
                    Label("Play order", systemImage: "play.fill")
                }
                .font(.caption)
                .controlSize(.small)
                .disabled(orderedSelectedIDs.count < 2)
                .help("Runs through the fixtures in the order they'll be written "
                      + "to the CSV, 1 → \(max(orderedSelectedIDs.count, 1)).")
            }
            .padding(10)
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
    /// what a patch normally follows; sorting a column re-orders them. The
    /// list always reads in the order the screen is built.
    private var fixturesOfType: [MVRFixture] {
        document.fixtures
            .filter { $0.gdtfSpec == selectedSpec }
            .sorted(using: sortOrder)
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
        // Worked out once for the whole screen rather than by each piece
        // that needs it: `drawnPlacements` filters and sorts the document,
        // and it used to be asked for eight times per render.
        let drawn = drawnPlacements
        let grid = gridSize(for: drawn)
        // Room for the card, so it falls inside the grid's own rectangle.
        // Outside it the card still *drew*, but SwiftUI delivers no
        // clicks past a view's bounds — which is why its field couldn't
        // be typed into and its buttons did nothing.
        let canvas = cardAnchor == nil
            ? grid
            : CGSize(width: grid.width + Self.editorWidth + 24, height: grid.height + 260)

        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                sizeField("Across", value: Binding(
                    get: { block.columns },
                    set: { block.resize(columns: $0, rows: block.rows); fill = nil }),
                    range: 1...256)

                sizeField("High", value: Binding(
                    get: { block.rows },
                    set: { block.resize(columns: block.columns, rows: $0); fill = nil }),
                    range: 1...64)

                Divider().frame(height: 18)

                Text("Fixture Rotation:")
                Picker("", selection: $rotation) {
                    ForEach(DisguisePixelMap.Rotation.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: rotation) { _, _ in fill = nil }
                .help("Turn the fixture. A line on its end makes a tower, and the pixel "
                      + "coordinates follow.")

                Text("Pixel Direction:")
                Picker("", selection: Binding(
                    get: { block.order },
                    set: { block.order = $0; fill = nil })) {
                    ForEach(DisguisePixelMap.PixelOrder.allCases) { order in
                        Label(order.label, systemImage: order.symbol).tag(order)
                    }
                }
                .frame(width: 170)
                .help("Which way the pixels are counted inside one fixture. "
                      + "Snaking is what most battens and tiles do.")

                Text("Pixel 1 at:")
                Picker("", selection: Binding(
                    get: { block.start },
                    set: { block.start = $0; fill = nil })) {
                    ForEach(DisguisePixelMap.PixelStart.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 130)
                .help("The corner the count starts from, before the fixture is "
                      + "turned. Turning a fixture 90° puts its top-left end on "
                      + "the right, so this is what brings pixel 1 back to the left.")

                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // The second line: how the fixtures sit next to each other,
            // and where the whole thing stands. One line of this had the
            // labels wrapping two words deep.
            HStack(spacing: 16) {
                gapControls

                Divider().frame(height: 18)

                // The offset is typed into the pixel itself; the prompt
                // to do so is on the grid, where the pixels are.
                Text("\(block.filledCount) of \(block.cellCount) pixels given an offset.")
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Clear All…", role: .destructive) { isClearing = true }
                    .disabled(block.filledCount == 0 && !gap.isActive
                              && rotation == .none && block.order == .rows
                              && block.start == .topLeft)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            Text("\(drawnPlacements.count) × \(selectedTypeName), turned "
                 + "\(rotation.label). Hover a fixture to work on it — "
                 + "they all share one layout.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            if block.filledCount == 0 {
                // On the grid rather than at the end of the toolbar: it is
                // the only thing to do on this screen, and the pixels are
                // where the eye already is.
                HStack(spacing: 8) {
                    Image(systemName: "hand.point.up.left.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Click the first pixel to set its DMX offset.")
                        .fontWeight(.medium)
                    Text("The rest are then offered in grey.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.10),
                            in: Capsule())
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 0) {
                GeometryReader { proxy in
                    // Shrink to fit only when it nearly fits; past that it
                    // scrolls, in both directions. Measured on the grid
                    // itself, so opening a card doesn't shrink the view.
                    let scale = gridScale(fitting: proxy.size, grid: grid)
                    ScrollView([.horizontal, .vertical]) {
                        pixelGrid(drawn: drawn, grid: grid, canvas: canvas)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: canvas.width * scale,
                                   height: canvas.height * scale,
                                   alignment: .topLeading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                    // Asked of the scroll view directly rather than
                    // measured through a preference: the preference
                    // reported the padded, scaled frame, which left the
                    // drawing culling to a rectangle that didn't line up
                    // with what was on screen — fixtures in plain sight
                    // went missing.
                    .onScrollGeometryChange(for: CGRect.self) { geometry in
                        CGRect(origin: geometry.contentOffset, size: geometry.containerSize)
                    } action: { _, shown in
                        let inGrid = CGRect(
                            x: (shown.minX - 20) / scale, y: (shown.minY - 14) / scale,
                            width: shown.width / scale, height: shown.height / scale)
                        // Only once it has moved a cell's worth, so a
                        // scroll is a handful of updates rather than one
                        // per frame.
                        if abs(inGrid.minX - visibleRect.minX) > PixelGridMetrics.cellWidth
                            || abs(inGrid.minY - visibleRect.minY) > PixelGridMetrics.cellHeight
                            || inGrid.size != visibleRect.size {
                            visibleRect = inGrid
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }

                splitter(width: $csvWidth, startWidth: $csvDragStart)

                CSVPreview(
                    placements: placements,
                    block: block,
                    rotation: rotation)
                    .equatable()
                    .frame(width: csvWidth)
            }
        }
    }

    private static let cellWidth = PixelGridMetrics.cellWidth
    private static let cellHeight = PixelGridMetrics.cellHeight
    private static let cellGap = PixelGridMetrics.gap

    /// Where the cells stop shrinking. Below this the numbers stop being
    /// readable, and scrolling is the better trade — which is what a
    /// screen's worth of fixtures needs anyway.
    private static let minimumGridScale: CGFloat = 0.75

    /// The grid at full size, before any fitting.
    private func gridSize(for placements: [DisguisePixelMap.Placement]) -> CGSize {
        let drawn = DisguisePixelMap.screenSize(
            placements: placements, block: block, rotation: rotation)
        // Room for the caption under each fixture — or beside it when
        // they are stacked. Without it the canvas clips its own labels.
        return CGSize(
            width: CGFloat(drawn.width) * Self.cellWidth
                 + CGFloat(max(0, drawn.width - 1)) * Self.cellGap
                 + (rotation.isUpright ? 110 : 0),
            height: CGFloat(drawn.height) * Self.cellHeight
                 + CGFloat(max(0, drawn.height - 1)) * Self.cellGap
                 + (rotation.isUpright ? 0 : 18))
    }

    /// How much to shrink the grid by to get all of it on screen.
    ///
    /// The room taken off allows for the padding either side and for the
    /// scroll bars, so a grid that only just fits isn't left sitting under
    /// one of them.
    private func gridScale(fitting available: CGSize, grid size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        let room = CGSize(width: max(1, available.width - 48),
                          height: max(1, available.height - 36))
        let fit = min(room.width / size.width, room.height / size.height)
        // A grid that nearly fits is shrunk the last little way, so a
        // tower isn't cut off by one row. Anything bigger is left at full
        // size and scrolled — shrinking a whole screen of fixtures to fit
        // would make every number on it unreadable.
        return fit >= Self.minimumGridScale ? min(1, fit) : 1
    }

    /// One of the two block dimensions, typed in or stepped.
    private func sizeField(
        _ title: String, value: Binding<Int>, range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
            TextField("", value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }),
                format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 46)
                .multilineTextAlignment(.trailing)
            Stepper("", value: value, in: range)
                .labelsHidden()
        }
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
    /// The offer to fill the rest in, on the grid beside the pixel that
    /// prompted it — the same card the offset is typed into, because it
    /// answers the same question and the eye is already there.
    private var fillCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Fill the other \(suggestions.count) pixels",
                  systemImage: "wand.and.stars")
                .font(.headline)

            HStack(spacing: 6) {
                Text("counting up in")
                TextField("", value: Binding(
                    get: { fill?.step ?? 3 },
                    set: { fill?.step = max(1, $0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                Text("from \(fill?.value ?? 0)")
            }
            .font(.callout)

            Text("Shown in grey on the grid until you accept.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Use these") { applySuggestions() }
                    .buttonStyle(.borderedProminent)
                Button("No thanks") { fill = nil }
            }
        }
        .padding(14)
        .frame(width: Self.editorWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1))
        .shadow(radius: 12, y: 4)
    }

    /// Every fixture that will be in the CSV, each drawn as the block of
    /// pixels it is, at the place it lands on the screen.
    ///
    /// One fixture used to be enough — they all share a layout, so 24 of
    /// them was the same picture 24 times. What it couldn't show is the
    /// screen: where the fixtures sit relative to each other, how the gap
    /// between them reads, and how wide the thing ends up. Drawn a fixture
    /// at a time rather than square by square, so hovering is one handler
    /// per fixture rather than one per pixel.
    private func pixelGrid(
        drawn: [DisguisePixelMap.Placement], grid: CGSize, canvas: CGSize
    ) -> some View {
        // Everything the grid needs, worked out once. Each of these used
        // to be a computed property asked for inside the drawing loop —
        // `suggestions` rebuilt its dictionary per cell, and naming a
        // fixture re-filtered and re-sorted the whole document per block,
        // which is what made a screen of fixtures crawl.
        let size = DisguisePixelMap.size(of: block, rotation: rotation)
        let cells = turnedCells
        let ranks = block.ranks
        let suggested = suggestions
        let fixtures = laidOutFixtures
        let captions = (0..<drawn.count).map { blockCaption(forFixtureAt: $0, in: fixtures) }
        let units = (0..<drawn.count).map { unitNumber(ofFixtureAt: $0, in: fixtures) }
        // While a card is open the fixture being edited stays the lit
        // one, whatever the cursor is doing.
        let lit = cardAnchor != nil
            ? min(cardFixture, drawn.count - 1)
            : min(hoveredFixture ?? 0, drawn.count - 1)

        return ZStack(alignment: .topLeading) {
            // Every other fixture is drawn in a single pass rather than
            // built as views. A hundred fixtures is three thousand pixels,
            // and three thousand buttons with three labels each is tens of
            // thousands of views for a picture nobody clicks on — the
            // fixture in hand is the only one that has to be interactive.
            // Its own view, compared rather than rebuilt: the drawing
            // depends on the layout and the offsets, not on which fixture
            // the cursor is over, so hovering and scrolling leave it
            // alone entirely. It draws every fixture, including the one
            // in hand, which is then covered by the interactive copy.
            PixelCanvas(
                placements: drawn,
                block: block,
                rotation: rotation,
                suggested: suggested,
                captions: captions,
                canvasSize: grid,
                visible: visibleRect)
                .equatable()

            if drawn.indices.contains(lit) {
                fixtureBlock(placement: drawn[lit], size: size, cells: cells,
                             ranks: ranks, suggested: suggested,
                             caption: captions.indices.contains(lit) ? captions[lit] : "")
                    // Opaque, because the drawn copy of this fixture is
                    // still underneath it.
                    .background(Color(nsColor: .windowBackgroundColor))
                    .offset(
                        x: CGFloat(drawn[lit].originX) * Self.pitchX,
                        y: CGFloat(drawn[lit].originY) * Self.pitchY)
            }

            // Drawn into the grid rather than presented as a popover.
            // A popover anchored to a cell inside a scrolled, scaled
            // stack would not show at all; a card is just another view,
            // and it follows the pixel as Set walks along the fixture.
            // Hung off the fixture the pixel was clicked on, not the one
            // the cursor happens to be over: a card that moved house on
            // every hover took its half-typed field with it.
            if let anchor = cardAnchor,
               let spot = editorSpot(for: anchor,
                                     on: drawn[min(cardFixture, drawn.count - 1)],
                                     grid: grid) {
                // One card at a time. Typing an offset raises the offer
                // to do the rest, and that question comes first: answer
                // it and the next pixel's offset is asked for, decline it
                // and the same thing happens. Both at once was two
                // questions about the same pixel.
                Group {
                    if fill != nil, !suggested.isEmpty {
                        fillCard
                    } else if let selectedCell {
                        offsetEditor(column: selectedCell % block.columns,
                                     row: selectedCell / block.columns,
                                     number: ranks[selectedCell] + 1)
                    }
                }
                .id("pixel-card")
                .offset(x: spot.x, y: spot.y)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        // The drawn fixtures are a picture, not views, so without this
        // the only hoverable thing on the grid was the one fixture built
        // as views — hovering any of the others did nothing at all.
        .contentShape(Rectangle())
        // One hover test for the whole grid, worked out from the cursor's
        // position: a tracking area per fixture was a tracking area per
        // fixture.
        .overlay(alignment: .topLeading) {
            // Not while a card is open: the two were landing on top of
            // each other, and the card is the one being used.
            if let hoveredPixel, cardAnchor == nil {
                pixelReadout(hoveredPixel)
                    .offset(x: hoveredPixel.anchor.x + Self.cellWidth + 10,
                            y: hoveredPixel.anchor.y + Self.cellHeight + 6)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            // Nothing moves while a card is open: every hover was a
            // state change, and a state change under a text field being
            // typed into is how keystrokes get lost.
            guard cardAnchor == nil else { return }

            switch phase {
            case .active(let point):
                let index = fixtureIndex(at: point, in: drawn, size: size)
                if let index, hoveredFixture != index { hoveredFixture = index }
                // Pinned to the pixel rather than to the cursor: hanging
                // it off the pointer meant new state on every tick of
                // mouse movement, and with it a redraw of the whole grid.
                let pixel = pixelInfo(at: point, in: drawn, size: size, cells: cells,
                                      ranks: ranks, suggested: suggested, units: units)
                if hoveredPixel != pixel { hoveredPixel = pixel }
            case .ended:
                if hoveredFixture != nil { hoveredFixture = nil }
                if hoveredPixel != nil { hoveredPixel = nil }
            @unknown default:
                break
            }
        }
    }

    /// The pixel under the cursor, read off the layout rather than from a
    /// view: the fixtures that aren't in hand are drawn, not built, so
    /// there is nothing there to hover.
    private func pixelInfo(
        at point: CGPoint,
        in drawn: [DisguisePixelMap.Placement],
        size: (width: Int, height: Int),
        cells: [Int: (column: Int, row: Int)],
        ranks: [Int],
        suggested: [Int: Int],
        units: [String]
    ) -> HoveredPixel? {
        guard let index = fixtureIndex(at: point, in: drawn, size: size) else { return nil }
        let placement = drawn[index]

        let localX = Int((point.x - CGFloat(placement.originX) * Self.pitchX) / Self.pitchX)
        let localY = Int((point.y - CGFloat(placement.originY) * Self.pitchY) / Self.pitchY)
        guard localX >= 0, localX < size.width, localY >= 0, localY < size.height,
              let source = cells[localY * size.width + localX]
        else { return nil }

        let cell = source.row * block.columns + source.column
        let offset = block.offset(column: source.column, row: source.row) ?? suggested[cell]
        return HoveredPixel(
            coordinate: "\(placement.originX + localX),\(placement.originY + localY)",
            address: Self.patchLabel(address: placement.address, offset: offset),
            number: ranks[cell] + 1,
            unit: units.indices.contains(index) ? units[index] : "–",
            // The fixture's own address, which every offset is counted
            // from — the same for all of its pixels.
            fixtureAddress: Self.patchLabel(address: placement.address, offset: 1),
            anchor: CGPoint(
                x: (CGFloat(placement.originX) + CGFloat(localX)) * Self.pitchX,
                y: (CGFloat(placement.originY) + CGFloat(localY)) * Self.pitchY))
    }

    /// The hovered pixel's three facts, in the order they are asked about.
    private func pixelReadout(_ pixel: HoveredPixel) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                Text("X, Y:").foregroundStyle(.secondary)
                Text(pixel.coordinate).monospacedDigit()
            }
            GridRow {
                Text("Pixel DMX Address:").foregroundStyle(.secondary)
                Text(pixel.address).monospacedDigit()
            }
            GridRow {
                Text("Pixel Number:").foregroundStyle(.secondary)
                Text("\(pixel.number)").monospacedDigit()
            }
            GridRow {
                Text("Unit Number:").foregroundStyle(.secondary)
                Text(pixel.unit).monospacedDigit()
            }
            GridRow {
                Text("Fixture Address:").foregroundStyle(.secondary)
                Text(pixel.fixtureAddress).monospacedDigit()
            }
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
        .shadow(radius: 6, y: 2)
    }

    private static var pitchX: CGFloat { cellWidth + cellGap }
    private static var pitchY: CGFloat { cellHeight + cellGap }

    /// Which fixture the cursor is over, or nil between them.
    private func fixtureIndex(
        at point: CGPoint,
        in drawn: [DisguisePixelMap.Placement],
        size: (width: Int, height: Int)
    ) -> Int? {
        for (index, placement) in drawn.enumerated() {
            let rect = CGRect(
                x: CGFloat(placement.originX) * Self.pitchX,
                y: CGFloat(placement.originY) * Self.pitchY,
                width: CGFloat(size.width) * Self.pitchX - Self.cellGap,
                height: CGFloat(size.height) * Self.pitchY - Self.cellGap)
            if rect.contains(point) { return index }
        }
        return nil
    }

    /// The fixture in hand, built as views because it is the one that is
    /// clicked, typed into and read in detail.
    private func fixtureBlock(
        placement: DisguisePixelMap.Placement,
        size: (width: Int, height: Int),
        cells: [Int: (column: Int, row: Int)],
        ranks: [Int],
        suggested: [Int: Int],
        caption: String
    ) -> some View {
        VStack(spacing: Self.cellGap) {
            ForEach(0..<size.height, id: \.self) { y in
                HStack(spacing: Self.cellGap) {
                    ForEach(0..<size.width, id: \.self) { x in
                        if let source = cells[y * size.width + x] {
                            pixelCell(
                                column: source.column, row: source.row,
                                x: placement.originX + x, y: placement.originY + y,
                                number: ranks[source.row * block.columns + source.column] + 1,
                                suggested: suggested[
                                    source.row * block.columns + source.column])
                        } else {
                            Color.clear
                                .frame(width: Self.cellWidth, height: Self.cellHeight)
                        }
                    }
                }
            }
        }
        // The box, drawn on the block's own bounds and pushed a point into
        // the channel between the cells, so it can't overlap the fixture
        // next to it.
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .inset(by: -1)
                .stroke(Color.accentColor.opacity(0.9), lineWidth: 1.5))
        // Laid over rather than stacked under, so naming the fixture
        // doesn't change where its pixels sit.
        .overlay(alignment: .topLeading) {
            Text(caption)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .fixedSize()
                // Beside a stack, under a row — the same places the drawn
                // fixtures put theirs.
                .offset(
                    x: rotation.isUpright
                        ? CGFloat(size.width) * Self.pitchX - Self.cellGap + 8
                        : 2,
                    y: rotation.isUpright
                        ? 2
                        : CGFloat(size.height) * Self.pitchY - Self.cellGap + 3)
        }
    }

    /// Where each of the fixture's own cells lands inside its block once
    /// the fixture is turned, keyed by position in the turned block.
    ///
    /// Worked out once and handed to every fixture: they share a layout,
    /// so they share this answer too.
    private var turnedCells: [Int: (column: Int, row: Int)] {
        let size = DisguisePixelMap.size(of: block, rotation: rotation)
        var map: [Int: (column: Int, row: Int)] = [:]
        map.reserveCapacity(block.cellCount)
        for row in 0..<block.rows {
            for column in 0..<block.columns {
                let at = DisguisePixelMap.position(
                    column: column, row: row, block: block, rotation: rotation)
                map[at.y * size.width + at.x] = (column, row)
            }
        }
        return map
    }

    /// The fixtures to draw: the ones going in the CSV, or a single block
    /// at the origin before any are ticked, so the editor still works.
    private var drawnPlacements: [DisguisePixelMap.Placement] {
        let placements = self.placements
        return placements.isEmpty
            ? [DisguisePixelMap.Placement(address: 1, originX: 0, originY: 0)]
            : placements
    }

    private func pixelCell(
        column: Int, row: Int, x: Int, y: Int, number: Int, suggested proposal: Int?
    ) -> some View {
        let index = row * block.columns + column
        let offset = block.offset(column: column, row: row)
        let suggested = offset == nil ? proposal : nil
        let isSelected = selectedCell == index

        return Button {
            selectedCell = index
            cardFixture = hoveredFixture ?? 0
            hoveredPixel = nil
            offsetText = offset.map(String.init) ?? ""
            offsetFocused = true
        } label: {
            VStack(spacing: 0) {
                // Which pixel this is, counted the way the order runs.
                // The number you look for first, so the one that leads.
                Text("\(number)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(offset.map(String.init) ?? suggested.map(String.init) ?? "–")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    // Grey, and lighter still than the secondary label
                    // colour: a suggested number has to be legible enough
                    // to check and plainly not a number anyone typed.
                    .foregroundStyle(offset == nil
                                     ? Color.secondary.opacity(suggested == nil ? 0.3 : 0.55)
                                     : .secondary)
                Text("\(x),\(y)")
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.tertiary)
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
    }

    /// The MVR Fixture ID of the fixture drawn at this place — the unit
    /// number, the same for every one of its pixels.
    private func unitNumber(ofFixtureAt index: Int, in fixtures: [MVRFixture]) -> String {
        guard fixtures.indices.contains(index),
              let id = fixtures[index].currentFixtureID
        else { return "–" }
        return String(id)
    }

    /// What is written under (or beside) each fixture on the grid.
    private func blockCaption(forFixtureAt index: Int, in fixtures: [MVRFixture]) -> String {
        let unit = unitNumber(ofFixtureAt: index, in: fixtures)
        guard fixtures.indices.contains(index),
              let address = fixtures[index].currentAddress
        else { return "Unit \(unit)" }
        let split = MVRFixture.universeAndChannel(fromAbsoluteAddress: address)
        return "Unit \(unit)  ·  \(split.universe).\(split.channel)"
    }

    /// The real address a pixel lands on, as universe.channel.
    private static func patchLabel(address: Int, offset: Int?) -> String {
        guard let offset else { return "–" }
        let absolute = address + offset - 1
        guard absolute >= 1 else { return "–" }
        let split = MVRFixture.universeAndChannel(fromAbsoluteAddress: absolute)
        return "\(split.universe).\(split.channel)"
    }

    private static let editorWidth: CGFloat = 320

    /// The pixel the cards hang from: the one being typed into, or the one
    /// a fill was offered from once the editor has been closed.
    private var cardAnchor: Int? { selectedCell ?? fill?.anchor }

    /// Where the editor card sits: under the selected pixel of the first
    /// fixture, pulled back inside the grid at the edges so it can't be
    /// left hanging off the end of the scroll area.
    private func editorSpot(
        for cell: Int, on placement: DisguisePixelMap.Placement, grid: CGSize
    ) -> CGPoint? {
        guard block.offsets.indices.contains(cell) else { return nil }
        let at = DisguisePixelMap.position(
            column: cell % block.columns, row: cell / block.columns,
            block: block, rotation: rotation)
        let x = CGFloat(placement.originX + at.x) * (Self.cellWidth + Self.cellGap)
        let y = CGFloat(placement.originY + at.y) * (Self.cellHeight + Self.cellGap)
        return CGPoint(
            x: min(max(0, x - 20), max(0, grid.width - 40)),
            y: y + Self.cellHeight + 10)
    }

    /// The offset for one pixel, drawn beneath the pixel itself.
    private func offsetEditor(column: Int, row: Int, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pixel \(number)")
                    .font(.headline)
                Spacer()
                Button {
                    selectedCell = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            Text("Column \(column + 1), row \(row + 1). The DMX offset is counted "
                 + "from the fixture's own address: a line patched at 1 whose first "
                 + "pixel is at 6 has an offset of 6.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("offset", text: $offsetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($offsetFocused)
                    .onSubmit { commitOffset() }
                Button("Set") { commitOffset() }
                    .keyboardShortcut(.defaultAction)
                Button("Clear") {
                    block.setOffset(nil, column: column, row: row)
                    offsetText = ""
                }
            }
        }
        .padding(14)
        .frame(width: Self.editorWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1))
        .shadow(radius: 12, y: 4)
        // Asked for after the field exists, and again each time the card
        // walks to the next pixel. Setting it in the same breath as the
        // click left the keyboard where it was — which is how typing an
        // offset ended up changing the Across setting.
        .task(id: selectedCell) {
            try? await Task.sleep(for: .milliseconds(60))
            offsetFocused = true
        }
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

    /// Back to an empty layout of the same size.
    private func clearLayout() {
        block = DisguisePixelMap.Block(columns: block.columns, rows: block.rows)
        rotation = .none
        showsGap = false
        gap = .none
        fill = nil
        selectedCell = nil
        offsetText = ""
    }

    private func applySuggestions() {
        for (index, value) in suggestions {
            block.setOffset(value, column: index % block.columns, row: index / block.columns)
        }
        fill = nil
        // Every pixel has an answer now, so asking for one would be a
        // box in the way of looking at the result.
        selectedCell = nil
    }

    // MARK: - Derived

    /// The ticked fixtures that have an address, in layout order. These
    /// are the ones that become the screen, one for one with
    /// `placements`, so a block on the grid can say which fixture it is.
    private var laidOutFixtures: [MVRFixture] {
        fixturesOfType.filter { selectedFixtureIDs.contains($0.id) && $0.currentAddress != nil }
    }

    private var placements: [DisguisePixelMap.Placement] {
        DisguisePixelMap.placements(
            addresses: laidOutFixtures.compactMap(\.currentAddress),
            block: block, rotation: rotation,
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
        // number into every one of them in turn — next along the order
        // being counted, which on a snaking fixture doubles back.
        let sequence = block.sequence
        if let place = sequence.firstIndex(of: selectedCell),
           place + 1 < sequence.count {
            let next = sequence[place + 1]
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


/// The sizes both layers of the pixel view measure in.
private enum PixelGridMetrics {
    static let cellWidth: CGFloat = 46
    static let cellHeight: CGFloat = 46
    static let gap: CGFloat = 3
    static var pitchX: CGFloat { cellWidth + gap }
    static var pitchY: CGFloat { cellHeight + gap }
}

/// Every fixture on the screen, drawn in one pass.
///
/// A view of its own, and `Equatable`, so SwiftUI can skip it: the
/// picture depends on the layout and the offsets, and neither changes
/// when the cursor moves. Rebuilding thousands of labels on every mouse
/// move is what made a wide screen crawl.
private struct PixelCanvas: View, Equatable {
    let placements: [DisguisePixelMap.Placement]
    let block: DisguisePixelMap.Block
    let rotation: DisguisePixelMap.Rotation
    let suggested: [Int: Int]
    let captions: [String]
    let canvasSize: CGSize
    /// The part of the grid on screen. A screen 18,000 points wide is
    /// mostly not on it, and drawing the rest was the cost of every
    /// scroll. Empty means draw the lot.
    let visible: CGRect

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            draw(in: &context)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext) {
        let size = DisguisePixelMap.size(of: block, rotation: rotation)
        let cells = turnedCells(size: size)
        // The labels are the point of the picture, so they stay on for
        // any screen anyone is actually patching. The cap is there for
        // the pathological case — tens of thousands of cells, where each
        // one is a few pixels across and nothing could be read anyway.
        let showsLabels = placements.count * block.cellCount <= 20_000
        let fade: CGFloat = 0.55

        // A margin either side, so a fixture is already drawn by the
        // time it is scrolled into view.
        let shown = visible.isEmpty
            ? nil
            : visible.insetBy(dx: -PixelGridMetrics.pitchX * 8,
                              dy: -PixelGridMetrics.pitchY * 8)

        for (index, placement) in placements.enumerated() {
            let originX = CGFloat(placement.originX) * PixelGridMetrics.pitchX
            let originY = CGFloat(placement.originY) * PixelGridMetrics.pitchY

            let box = CGRect(
                x: originX - 1, y: originY - 1,
                width: CGFloat(size.width) * PixelGridMetrics.pitchX - PixelGridMetrics.gap + 2,
                height: CGFloat(size.height) * PixelGridMetrics.pitchY - PixelGridMetrics.gap + 2)
            if let shown, !shown.intersects(box) { continue }

            context.stroke(
                Path(roundedRect: box, cornerRadius: 6),
                with: .color(.secondary.opacity(0.35 * fade)), lineWidth: 1)

            // Which fixture this block is. Under it for a row, beside it
            // for a stack, where the room is either way.
            context.draw(
                Text(captions.indices.contains(index) ? captions[index] : "")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary.opacity(0.8 * fade)),
                at: rotation.isUpright
                    ? CGPoint(x: box.maxX + 8, y: box.minY + 8)
                    : CGPoint(x: box.minX + 2, y: box.maxY + 9),
                anchor: .leading)

            for (key, source) in cells {
                let localX = key % size.width
                let localY = key / size.width
                let rect = CGRect(
                    x: originX + CGFloat(localX) * PixelGridMetrics.pitchX,
                    y: originY + CGFloat(localY) * PixelGridMetrics.pitchY,
                    width: PixelGridMetrics.cellWidth, height: PixelGridMetrics.cellHeight)

                let cellIndex = source.row * block.columns + source.column
                let offset = block.offset(column: source.column, row: source.row)
                let proposed = offset == nil ? suggested[cellIndex] : nil
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 4),
                    with: .color(offset == nil
                                 ? Color.secondary.opacity(0.12 * fade)
                                 : Color.accentColor.opacity(0.28 * fade)))

                guard showsLabels else { continue }
                // Where it lands, and the address it will carry there.
                // The offset itself is the same on every fixture, so it
                // is the one number worth not repeating.
                context.draw(
                    Text("\(placement.originX + localX),\(placement.originY + localY)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary.opacity(fade)),
                    at: CGPoint(x: rect.midX, y: rect.midY - 6))
                context.draw(
                    Text(Self.patchLabel(address: placement.address, offset: offset ?? proposed))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(.secondary.opacity(0.7 * fade)),
                    at: CGPoint(x: rect.midX, y: rect.midY + 7))
            }
        }
    }

    private func turnedCells(size: (width: Int, height: Int)) -> [Int: (column: Int, row: Int)] {
        var map: [Int: (column: Int, row: Int)] = [:]
        map.reserveCapacity(block.cellCount)
        for row in 0..<block.rows {
            for column in 0..<block.columns {
                let at = DisguisePixelMap.position(
                    column: column, row: row, block: block, rotation: rotation)
                map[at.y * size.width + at.x] = (column, row)
            }
        }
        return map
    }

    private static func patchLabel(address: Int, offset: Int?) -> String {
        guard let offset else { return "–" }
        let absolute = address + offset - 1
        guard absolute >= 1 else { return "–" }
        let split = MVRFixture.universeAndChannel(fromAbsoluteAddress: absolute)
        return "\(split.universe).\(split.channel)"
    }
}


/// The file as it will be written, beside the grid that makes it.
///
/// Equatable for the same reason the canvas is: the rows depend on the
/// layout and the offsets, not on where the cursor is. A `Table` rather
/// than a list of lines, so the four columns stay in their places and
/// the header stays put while the rows scroll under it.
private struct CSVPreview: View, Equatable {
    let placements: [DisguisePixelMap.Placement]
    let block: DisguisePixelMap.Block
    let rotation: DisguisePixelMap.Rotation

    /// One line of the file.
    struct Row: Identifiable {
        let id: Int
        let x: Int
        let y: Int
        let universe: Int
        let channel: Int
    }

    var body: some View {
        let rows = DisguisePixelMap
            .pixels(placements: placements, block: block, rotation: rotation)
            .enumerated()
            .map { Row(id: $0.offset, x: $0.element.x, y: $0.element.y,
                       universe: $0.element.universe, channel: $0.element.channel) }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CSV preview")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(rows.count.formatted()) row\(rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if rows.isEmpty {
                Text("Give a pixel an offset and its row appears here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                Spacer()
            } else {
                Table(rows) {
                    TableColumn("x") { Text("\($0.x)").monospacedDigit() }
                        .width(min: 26, ideal: 34)
                    TableColumn("y") { Text("\($0.y)").monospacedDigit() }
                        .width(min: 26, ideal: 34)
                    TableColumn("universe") { Text("\($0.universe)").monospacedDigit() }
                        .width(min: 52, ideal: 64)
                    TableColumn("channel") { Text("\($0.channel)").monospacedDigit() }
                        .width(min: 52, ideal: 64)
                }
                .font(.system(size: 11).monospacedDigit())
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
