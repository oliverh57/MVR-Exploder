import SwiftUI
import AppKit

/// Everything that can be done with the open file.
///
/// What used to be the mode picker, now reached only once an MVR is open:
/// every tool here works on that one document, so an edit made in one —
/// a renumber, a merge, a fixed address — is already there in the next.
/// The things that are about the whole file rather than one way of
/// editing it live here too: the 3D view, the ID map, and writing it out.
struct ToolsView: View {
    @ObservedObject var document: MVRDocument
    let onOpen: (AppMode) -> Void

    @State private var showExportSheet = false
    @State private var showPatchPDFSheet = false
    @State private var isConfirmingClose = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Centred both ways when the window has room, scrolling when
            // it hasn't.
            GeometryReader { space in
            ScrollView {
                // One column per kind of work, read left to right in the
                // order it's usually done: edit, look it over, write it out.
                HStack(alignment: .top, spacing: Self.columnGap) {
                    section("Edit") {
                        row("Single Edit", "Edit IDs, names, patch, layers and modes.", "square.and.pencil") {
                            onOpen(.singleEdit)
                        }
                        row("Smart Auto ID", "Number fixtures truss by truss.", "number.square") {
                            onOpen(.smartAutoID)
                        }
                        row("Compare & Merge", "Compare with another MVR and merge fixtures in.", "rectangle.split.2x1") {
                            onOpen(.compare)
                        }
                        row("Mode Swap", "See each type's modes and swap them in bulk.", "arrow.left.arrow.right.square") {
                            onOpen(.modeSwap)
                        }
                        // Patch Check is switched off until its findings
                        // can be trusted; the code is still in the project.
                        // row("Patch Check", "…", "exclamationmark.triangle") { … }
                    }

                    section("View") {
                        row("3D Viewer", "View the rig in 3D.", "cube.transparent") {
                            onOpen(.viewer3D)
                        }
                        row("Fixture ID Map", "See used IDs, gaps and clashes.", "square.grid.3x3") {
                            onOpen(.fixtureIDMap)
                        }
                        row("DMX Universe Map", "See used channels, free space and overlaps.", "rectangle.split.3x3") {
                            onOpen(.dmxUniverseMap)
                        }
                    }

                    section("Export") {
                        row("Export MVR", "Save a new MVR with your changes.", "square.and.arrow.up", prominent: true) {
                            showExportSheet = true
                        }
                        row("Patch PDF", "Print a patch list, with an optional 3D render.", "doc.richtext") {
                            showPatchPDFSheet = true
                        }
                        row("Disguise CSV", "Make a pixel-map CSV for Disguise.", "tablecells") {
                            onOpen(.disguiseCSV)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, minHeight: space.size.height)
            }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            MVRExportSheet(document: document) { result in
                showExportSheet = false
                switch result {
                case .exported(let name):
                    report("Exported \(name).")
                case .failed(let reason):
                    report("Export failed: \(reason)", isError: true)
                case .cancelled:
                    break
                }
            }
        }
        .sheet(isPresented: $showPatchPDFSheet) {
            PatchPDFSheet(document: document) { result in
                showPatchPDFSheet = false
                switch result {
                case .exported(let name):
                    report("Exported \(name).")
                case .failed(let reason):
                    report("Patch PDF export failed: \(reason)", isError: true)
                case .cancelled:
                    break
                }
            }
        }
        .confirmationDialog(
            "Close \(document.fileName) without exporting?",
            isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("Export First…") { showExportSheet = true }
            Button("Close Without Exporting", role: .destructive) { closeFile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes haven't been exported.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            FileSummary(
                document: document,
                note: message.map { Text($0).foregroundStyle(messageIsError ? .red : .green) })

            Spacer()

            Button("Close File…") {
                if document.hasUnexportedChanges {
                    isConfirmingClose = true
                } else {
                    closeFile()
                }
            }
            .help("Close this MVR and open another.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Columns

    private static let columnWidth: CGFloat = 260
    private static let columnGap: CGFloat = 20

    /// A heading over a grouped list of tools.
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 {
                            // Lined up with the titles, past the icons.
                            Divider().padding(.leading, 52)
                        }
                        rows[index]
                    }
                }
            }
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(width: Self.columnWidth)
    }

    private func row(
        _ title: String, _ subtitle: String, _ symbol: String,
        prominent: Bool = false, action: @escaping () -> Void
    ) -> some View {
        ToolRow(title: title, subtitle: subtitle, symbol: symbol,
                prominent: prominent, action: action)
    }

    // MARK: - Actions

    private func closeFile() {
        message = nil
        document.clear()
    }

    private func report(_ text: String, isError: Bool = false) {
        message = text
        messageIsError = isError
    }
}

/// One tool in a column: lit on hover, so it reads as something to click.
private struct ToolRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    /// The accent icon, for the one thing most visits end with.
    let prominent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .frame(width: 28)
                    .foregroundStyle(prominent ? Color.accentColor : .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovered ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// The export options and the save, for the one document everything works
/// on.
struct MVRExportSheet: View {
    @ObservedObject var document: MVRDocument

    enum Result {
        case exported(String)
        case failed(String)
        case cancelled
    }
    let onFinish: (Result) -> Void

    @State private var includeSceneGeometry = true
    @State private var assignLayersByFixtureType = false
    @State private var replaceAllWithDummyGDTFs = false
    @State private var cleanupEmptyClassesAndLayers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export MVR")
                .font(.headline)

            Toggle("Include scene geometry", isOn: $includeSceneGeometry)
            Text("Turn off to export fixtures only.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Assign fixture layers by type", isOn: $assignLayersByFixtureType)
            Text("One layer per fixture type. Everything else goes in a layer called NONE.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Replace all fixtures with dummy GDTFs", isOn: $replaceAllWithDummyGDTFs)
            Text("Use placeholder GDTFs for every fixture. Missing GDTFs always get one.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Cleanup empty classes and layers", isOn: $cleanupEmptyClassesAndLayers)
            Text("Remove unused layers and classes.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { onFinish(.cancelled) }
                Button("Choose Location & Export…") { export() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func export() {
        let options = MVRExportOptions(
            includeSceneGeometry: includeSceneGeometry,
            assignLayersByFixtureType: assignLayersByFixtureType,
            replaceAllWithDummyGDTFs: replaceAllWithDummyGDTFs,
            cleanupEmptyClassesAndLayers: cleanupEmptyClassesAndLayers)

        let panel = NSSavePanel()
        panel.prepareForExport(
            named: options.exportName(for: document.fileName, editTags: document.editTags),
            fileExtension: "mvr")
        guard panel.runModal() == .OK, let chosen = panel.url else {
            onFinish(.cancelled)
            return
        }
        let url = chosen.ensuringPathExtension("mvr")

        do {
            try MVRExporter.export(document, to: url, options: options)
            document.markExported()
            onFinish(.exported(url.lastPathComponent))
        } catch {
            onFinish(.failed(error.localizedDescription))
        }
    }
}

/// The patch PDF's settings, and the save.
///
/// The page settings first, then the 3D render: ticked, it shows a
/// preview of page 1, with the camera and layer controls folded away
/// beneath it until they're wanted.
struct PatchPDFSheet: View {
    @ObservedObject var document: MVRDocument
    let onFinish: (MVRExportSheet.Result) -> Void

    // Remembered between exports — the same show tends to get the same
    // PDF every time.
    @AppStorage("patchPDFByFixtureID") private var byFixtureID = false
    @AppStorage("patchPDFIncludesRender") private var includesStage = false
    @AppStorage("patchPDFPaper") private var paper = PatchPDFPageSetup.Paper.a4
    @AppStorage("patchPDFTextSize") private var textSize = PatchPDFPageSetup.TextSize.medium
    @AppStorage("patchPDFShowsViewOptions") private var showsViewOptions = false
    @State private var title = ""

    /// Built once, the first time the render is asked for, and kept while
    /// the sheet is open — every nudge of a control just re-aims it.
    @State private var stage: StageScene?
    @State private var isPreparing = false
    @State private var shot = StageScene.Shot.front
    @State private var preview: NSImage?
    @State private var isExporting = false

    private static let width: CGFloat = 660
    /// The render's shape, near enough the landscape page's less its
    /// margins and title.
    private static let previewSize = CGSize(width: 612, height: 382)

    private var defaultTitle: String { "Patch List — \(document.fileName)" }

    private var hasPositions: Bool {
        document.fixtures.contains { $0.position3D != nil }
    }

    private var showsStage: Bool { includesStage && hasPositions }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Patch PDF")
                .font(.headline)

            pageSettings

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Include a render on page one", isOn: $includesStage)
                    .disabled(!hasPositions)
                if !hasPositions {
                    Text("No fixtures in this file have positions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if showsStage {
                stagePreview
                viewOptionsToggle
                if showsViewOptions {
                    viewOptions
                }
            }

            HStack {
                if isExporting {
                    ProgressView().controlSize(.small)
                    Text("Rendering page 1…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onFinish(.cancelled) }
                    .disabled(isExporting)
                Button("Choose Location & Export…") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExporting || (showsStage && stage == nil))
            }
        }
        .padding(24)
        // Only as wide as the render needs when there is one.
        .frame(width: showsStage ? Self.width : 440)
        .task(id: showsStage) {
            if showsStage { await prepareStage() }
        }
        // Re-aimed a beat after the controls stop moving, so dragging a
        // slider is a handful of renders rather than one per pixel of it.
        .task(id: shot) {
            guard let stage else { return }
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            preview = stage.render(shot, size: Self.previewSize)
        }
    }

    // MARK: - The pages

    /// Labels to the right, controls down one edge: a standard settings
    /// form. The two short choices are pop-ups, so the only segmented
    /// control left is the one that changes what the pages are.
    private var pageSettings: some View {
        Form {
            TextField("Title:", text: $title, prompt: Text(defaultTitle))
            Picker("Lay out by:", selection: $byFixtureID) {
                Text("Fixture type").tag(false)
                Text("Fixture ID").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Paper:", selection: $paper) {
                ForEach(PatchPDFPageSetup.Paper.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Picker("Text size:", selection: $textSize) {
                ForEach(PatchPDFPageSetup.TextSize.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
        }
        .formStyle(.columns)
    }

    // MARK: - The render

    private var stagePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.25))
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(Self.previewSize.width / Self.previewSize.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(isPreparing ? "Loading…" : "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: Self.previewSize.width, height: Self.previewSize.height)
    }

    /// The fold the camera and layer controls sit behind.
    private var viewOptionsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showsViewOptions.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsViewOptions ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                Text("Adjust the view")
                if !showsViewOptions, shot != .front {
                    Text("— adjusted")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private var viewOptions: some View {
        HStack(alignment: .top, spacing: 24) {
            cameraControls
                .frame(width: 290)
            layerControls
        }
        .disabled(stage == nil)
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Camera")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                // Always a way back, whatever the sliders have been through.
                Button("Reset") { shot = StageScene.Shot(hiddenLayers: shot.hiddenLayers, fixturesOnly: shot.fixturesOnly) }
                    .controlSize(.small)
                    .disabled(shot.azimuth == 0 && shot.elevation == 30 && shot.zoom == 1)
            }

            HStack(spacing: 6) {
                preset("Front", azimuth: 0, elevation: 30)
                preset("Left", azimuth: -60, elevation: 30)
                preset("Right", azimuth: 60, elevation: 30)
                preset("Back", azimuth: 180, elevation: 30)
                preset("Top", azimuth: 0, elevation: 85)
            }

            slider("Orbit", value: $shot.azimuth, in: -180...180, reading: orbitReading)
                .help("Move the camera around the rig.")
            slider("Height", value: $shot.elevation, in: 0...85,
                   reading: "\(Int(shot.elevation.rounded()))°")
                .help("From eye level (0°) to overhead (85°).")
            slider("Zoom", value: $shot.zoom, in: 0.5...3,
                   reading: String(format: "%.1f×", shot.zoom))
        }
    }

    /// Where the camera is, in words rather than a bearing.
    private var orbitReading: String {
        let degrees = Int(shot.azimuth.rounded())
        switch abs(degrees) {
        case 0...4: return "Front"
        case 176...180: return "Behind"
        default: return "\(abs(degrees))° \(degrees < 0 ? "L" : "R")"
        }
    }

    private func preset(_ title: String, azimuth: Double, elevation: Double) -> some View {
        Button(title) {
            shot.azimuth = azimuth
            shot.elevation = elevation
            shot.zoom = 1
        }
        .controlSize(.small)
    }

    private func slider(
        _ title: String, value: Binding<Double>, in range: ClosedRange<Double>, reading: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 44, alignment: .leading)
            Slider(value: value, in: range)
            Text(reading)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var layerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layers")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let stage, !stage.layers.isEmpty {
                    Button(shot.hiddenLayers.isEmpty ? "None" : "All") {
                        shot.hiddenLayers = shot.hiddenLayers.isEmpty
                            ? Set(stage.layers.map(\.id))
                            : []
                    }
                    .controlSize(.small)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(stage?.layers ?? []) { layer in
                        Toggle(isOn: Binding(
                            get: { !shot.hiddenLayers.contains(layer.id) },
                            set: { isShown in
                                if isShown { shot.hiddenLayers.remove(layer.id) }
                                else { shot.hiddenLayers.insert(layer.id) }
                            })
                        ) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(layer.name)
                                    .lineLimit(1)
                                Text(layerDetail(layer))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)

            Toggle("Only render lighting fixtures", isOn: $shot.fixturesOnly)
                .toggleStyle(.checkbox)
                .help("Hide the stage, truss and venue.")
        }
    }

    private func layerDetail(_ layer: StageScene.Layer) -> String {
        var parts: [String] = []
        if layer.fixtureCount > 0 {
            parts.append("\(layer.fixtureCount) fixture\(layer.fixtureCount == 1 ? "" : "s")")
        }
        if layer.objectCount > 0 {
            parts.append("\(layer.objectCount) object\(layer.objectCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Work

    private func prepareStage() async {
        guard stage == nil, !isPreparing else { return }
        isPreparing = true
        let geometry = await StageScene.loadGeometry(for: document.originalFileURL)
        stage = StageScene(document: document, geometry: geometry)
        isPreparing = false
        preview = stage?.render(shot, size: Self.previewSize)
    }

    private func export() async {
        let panel = NSSavePanel()
        let baseName = (document.fileName as NSString).deletingPathExtension
        panel.prepareForExport(named: "\(baseName)_patch", fileExtension: "pdf")
        guard panel.runModal() == .OK, let chosen = panel.url else {
            onFinish(.cancelled)
            return
        }
        let url = chosen.ensuringPathExtension("pdf")

        var image: NSImage?
        if showsStage, let stage {
            isExporting = true
            // A beat for the progress line to draw before the render
            // takes the main thread.
            try? await Task.sleep(for: .milliseconds(30))
            // 16:10 at roughly 300 dpi across a landscape page.
            image = stage.render(shot, size: CGSize(width: 2800, height: 1750))
            isExporting = false
        }

        let trimmed = title.trimmingCharacters(in: .whitespaces)
        do {
            try MVRPatchPDFExporter.export(
                fixtures: document.fixtures,
                layout: byFixtureID ? .byFixtureID : .byFixtureType,
                documentTitle: trimmed.isEmpty ? defaultTitle : trimmed,
                stageImage: image,
                setup: PatchPDFPageSetup(paper: paper, textSize: textSize),
                to: url)
            onFinish(.exported(url.lastPathComponent))
        } catch {
            onFinish(.failed(error.localizedDescription))
        }
    }
}
