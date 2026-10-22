import SwiftUI
import SceneKit
import AppKit

/// The file's geometry two ways round, what it looks like, and tidying it.
///
/// **Symbols** lists every reusable piece of geometry with how many times
/// it's placed; **Objects** lists every non-lighting object — scene
/// objects, trusses, supports, video screens — with the model each one
/// draws. Either way the list is on the left, like the fixture table. A
/// chosen symbol renders on its own on the right; in Objects the right is
/// the whole scene, with the chosen objects lit up and the camera brought
/// to them, and their name, layer and position editable underneath.
///
/// Deleting and simplifying change the file, so this is an editing tool
/// like the others: it works on its own copy, every change can be undone,
/// and nothing reaches the file until Apply.
struct GeometryInspectorView: View {
    @ObservedObject var document: MVRDocument
    let onBack: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case symbols = "Symbols"
        case objects = "Objects"
        var id: String { rawValue }
    }

    private struct Loaded {
        let library: MVRSceneGeometryLoader.SymbolLibrary
        let inventory: GeometryInventory
    }

    /// What the preview is of, and from which read of the file.
    private struct PreviewKey: Hashable {
        let mode: Mode
        let symbol: String?
        let library: ObjectIdentifier?
    }

    private struct SceneKey: Hashable {
        let showing: Bool
        let revision: Int
    }

    private struct HighlightKey: Hashable {
        let objects: Set<String>
        let library: ObjectIdentifier?
    }

    @State private var loaded: Loaded?
    @State private var failed = false
    @State private var mode = Mode.objects
    /// An object tag — "Truss" — or nil for every type.
    @State private var kindFilter: String?
    @State private var filterText = ""
    @State private var symbolSelection: Set<String> = []
    @State private var objectSelection: Set<String> = []
    @State private var symbolSort = [KeyPathComparator(\GeometryInventory.Item.uses, order: .reverse)]
    @State private var objectSort = [KeyPathComparator(\GeometryInventory.Object.order)]
    /// The selected item's build; nil while it's being built.
    @State private var preview: MVRSceneGeometryLoader.SymbolPreview?
    @State private var isBuilding = false
    /// What the last delete, simplify or export did.
    @State private var message: String?
    @State private var messageIsError = false
    @State private var isSimplifying = false
    /// The sheet is for every mesh in the file, not the selection.
    @State private var isSimplifyingAll = false
    /// Each object's model fingerprint and material colours, for "Select
    /// All with Same…". Read in the background after each load.
    @State private var traits: [String: MVRSceneGeometryLoader.ObjectTraits]?
    /// The whole scene, for Objects. Built the first time it's shown, and
    /// again only after an edit that changes how it looks.
    @State private var scene: MVRSceneGeometryLoader.LoadedGeometry?
    @State private var sceneRevision: Int?
    /// The selected objects where they stand, drawn over the scene.
    @State private var highlight: MVRSceneGeometryLoader.SymbolPreview?
    /// The selection the camera was last brought to, so an edit that
    /// rebuilds the highlight doesn't pull the camera back to it.
    @State private var focusedSelection: Set<String> = []
    @State private var focusRequest = 0
    @State private var fitAllRequest = 0

    /// The formats offered for one item: OBJ for anything, FBX for a DCC.
    /// DXF is left to the 3D viewer, where whole layers go to CAD.
    private static let exportFormats: [MVRGeometryExport.Format] = [.obj, .fbx]

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader("Geometry Inspector", onBack: onBack)
            Divider()

            if let loaded {
                let inventory = loaded.inventory
                if inventory.items.isEmpty && inventory.objects.isEmpty {
                    placeholder("This file has no geometry.")
                } else {
                    controls(inventory)
                    Divider()
                    HSplitView {
                        list(inventory)
                            .frame(minWidth: 380, idealWidth: 520, maxWidth: 760)
                        detail(inventory)
                            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .task(id: previewKey) { await build(previewKey, from: loaded.library) }
                }
            } else if failed {
                placeholder("Couldn't read the geometry in this file.")
            } else {
                ProgressView("Reading geometry…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Every edit and undo moves the revision, and the list is read
        // again from the edited copy.
        .task(id: document.geometryRevision) { await load() }
        .task(id: loaded.map { ObjectIdentifier($0.library) }) { await loadTraits() }
        .task(id: SceneKey(showing: mode == .objects, revision: document.sceneRevision)) { await loadScene() }
        .task(id: HighlightKey(
            objects: mode == .objects ? objectSelection : [],
            library: loaded.map { ObjectIdentifier($0.library) })
        ) { await buildHighlight() }
        .onChange(of: mode) { _, _ in
            message = nil
            kindFilter = nil
        }
        .sheet(isPresented: $isSimplifying) {
            if let loaded {
                SimplifySheet(
                    library: loaded.library,
                    subject: isSimplifyingAll ? "every mesh in the file" : selectionDescription,
                    symbols: isSimplifyingAll
                        ? Set(loaded.inventory.items.map(\.id))
                        : (mode == .symbols ? symbolSelection : []),
                    objects: isSimplifyingAll
                        ? Set(loaded.inventory.objects.map(\.id))
                        : (mode == .objects ? objectSelection : []),
                    sharedThroughSymbols: !isSimplifyingAll && mode == .objects
                ) { result in
                    isSimplifying = false
                    isSimplifyingAll = false
                    guard let result else { return }
                    finishSimplify(result)
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mode, type and search

    private func controls(_ inventory: GeometryInventory) -> some View {
        HStack(spacing: 12) {
            Picker("View", selection: $mode) {
                Text("Symbols (\(inventory.items.count))").tag(Mode.symbols)
                Text("Objects (\(inventory.objects.count.formatted()))").tag(Mode.objects)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Symbols: each piece of reusable geometry. Objects: each scene object and the model it uses.")

            Picker("Type", selection: $kindFilter) {
                Text("All types").tag(String?.none)
                Divider()
                ForEach(kinds(inventory), id: \.tag) { kind in
                    Text("\(GeometryInventory.kindLabel(kind.tag)) (\(kind.count.formatted()))")
                        .tag(String?.some(kind.tag))
                }
            }
            .fixedSize()
            .help(mode == .symbols
                ? "Show the symbols placed by one type of object."
                : "Show one type of object.")

            Spacer()

            Button {
                isSimplifyingAll = true
                isSimplifying = true
            } label: {
                Label("Simplify All Meshes…", systemImage: "wand.and.stars")
            }
            .help("Reduce the triangles in every mesh in the file, to make a heavy file lighter.")

            TextField("Search", text: $filterText, prompt: Text(mode == .symbols ? "Filter by name" : "Filter by name, layer or model"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The object types in the file, most first.
    private func kinds(_ inventory: GeometryInventory) -> [(tag: String, count: Int)] {
        Dictionary(grouping: inventory.objects, by: \.kind)
            .map { (tag: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    // MARK: - The list

    private var query: String { filterText.trimmingCharacters(in: .whitespaces) }

    private func symbolRows(_ inventory: GeometryInventory) -> [GeometryInventory.Item] {
        inventory.items
            .filter { kindFilter.map($0.kinds.contains) ?? true }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted(using: symbolSort)
    }

    private func objectRows(_ inventory: GeometryInventory) -> [GeometryInventory.Object] {
        inventory.objects
            .filter { kindFilter == nil || $0.kind == kindFilter }
            .filter {
                query.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.layer.localizedCaseInsensitiveContains(query)
                    || $0.modelSummary.localizedCaseInsensitiveContains(query)
            }
            .sorted(using: objectSort)
    }

    private func list(_ inventory: GeometryInventory) -> some View {
        VStack(spacing: 0) {
            switch mode {
            case .symbols: symbolTable(symbolRows(inventory))
            case .objects: objectTable(objectRows(inventory))
            }
            Divider()
            listFooter(inventory)
        }
    }

    private func symbolTable(_ rows: [GeometryInventory.Item]) -> some View {
        Table(rows, selection: $symbolSelection, sortOrder: $symbolSort) {
            TableColumn("") { item in
                DeleteRowButton(help: "Remove this symbol, its placements, and any object left with no geometry") {
                    deleteSymbols([item.id])
                }
            }
            .width(28)

            TableColumn("Name", value: \.name) { item in
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.name)
            }
            TableColumn("Uses", value: \.uses) { item in
                Text("\(item.uses)")
                    .monospacedDigit()
                    .foregroundStyle(item.uses == 0 ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 56, max: 80)
            TableColumn("Meshes", value: \.meshCount) { item in
                Text("\(item.meshCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60, max: 80)
        }
        // As in Single Edit: right-clicking inside a selection acts on all
        // of it; right-clicking an unselected row acts on that row alone.
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Delete Symbol" : "Delete \(ids.count) Symbols", role: .destructive) {
                    deleteSymbols(ids)
                }
            }
        }
    }

    private func objectTable(_ rows: [GeometryInventory.Object]) -> some View {
        Table(rows, selection: $objectSelection, sortOrder: $objectSort) {
            TableColumn("") { object in
                DeleteRowButton(help: "Remove this object") {
                    deleteObjects([object.id])
                }
            }
            .width(28)

            TableColumn("Name", value: \.name) { object in
                Text(object.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(object.name == "Unnamed" ? .secondary : .primary)
            }
            TableColumn("Type", value: \.kind) { object in
                Text(GeometryInventory.kindName(object.kind))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90, max: 120)
            TableColumn("Layer", value: \.layer) { object in
                Text(object.layer)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 110)
            TableColumn("Model", value: \.modelSummary) { object in
                Text(object.modelSummary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(object.modelSummary == "—" ? .secondary : .primary)
                    .help(object.modelSummary)
            }
        }
        .contextMenu(forSelectionType: String.self) { keys in
            if !keys.isEmpty, let inventory = loaded?.inventory {
                selectSameItems(keys, in: inventory)
                Divider()
                Button(keys.count == 1 ? "Delete Object" : "Delete \(keys.count.formatted()) Objects", role: .destructive) {
                    deleteObjects(keys)
                }
            }
        }
    }

    // MARK: - Select All with Same…

    /// Right-click on objects: everything in the file that shares the
    /// model, a material, the type, the layer or the name with them.
    @ViewBuilder
    private func selectSameItems(_ keys: Set<String>, in inventory: GeometryInventory) -> some View {
        let chosen = inventory.objects.filter { keys.contains($0.id) }
        let models = Set(chosen.compactMap { traits?[$0.id]?.model })
        let sameModel = matching(inventory) { object in
            traits?[object.id]?.model.map(models.contains) ?? false
        }
        Button(traits == nil ? "Select All with Same Model (reading…)" : "Select All with Same Model (\(sameModel.count.formatted()))") {
            select(sameModel, sharing: "model")
        }
        .disabled(traits == nil || sameModel.isEmpty)

        let colours = chosen.reduce(into: Set<UInt32>()) { $0.formUnion(traits?[$1.id]?.colours ?? []) }
        Menu("Select All with Same Material") {
            if traits == nil {
                Text("Reading materials…")
            } else if colours.isEmpty {
                Text("No materials in these meshes")
            } else {
                ForEach(colours.sorted(), id: \.self) { colour in
                    let same = matching(inventory) { traits?[$0.id]?.colours.contains(colour) ?? false }
                    Button {
                        select(same, sharing: "material colour \(Self.hex(colour))")
                    } label: {
                        Label {
                            Text("\(Self.hex(colour)) — \(plural(same.count, "object"))")
                        } icon: {
                            Image(nsImage: Self.swatch(colour))
                        }
                    }
                }
            }
        }

        let kinds = Set(chosen.map(\.kind))
        let sameKind = matching(inventory) { kinds.contains($0.kind) }
        Button("Select All of Same Type (\(sameKind.count.formatted()))") { select(sameKind, sharing: "type") }

        let layers = Set(chosen.map(\.layerUUID))
        let sameLayer = matching(inventory) { layers.contains($0.layerUUID) }
        Button("Select All on Same Layer (\(sameLayer.count.formatted()))") { select(sameLayer, sharing: "layer") }

        let names = Set(chosen.map(\.name))
        let sameName = matching(inventory) { names.contains($0.name) }
        Button("Select All with Same Name (\(sameName.count.formatted()))") { select(sameName, sharing: "name") }
    }

    private func matching(
        _ inventory: GeometryInventory, _ test: (GeometryInventory.Object) -> Bool
    ) -> Set<String> {
        Set(inventory.objects.filter(test).map(\.id))
    }

    /// Selects across the whole file, so a filter that would hide some of
    /// them is cleared.
    private func select(_ keys: Set<String>, sharing what: String) {
        kindFilter = nil
        filterText = ""
        objectSelection = keys
        report("Selected \(plural(keys.count, "object")) with the same \(what).")
    }

    private static func hex(_ colour: UInt32) -> String {
        String(format: "#%06X", colour)
    }

    private static func swatch(_ colour: UInt32) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            NSColor(
                srgbRed: CGFloat(colour >> 16 & 0xFF) / 255,
                green: CGFloat(colour >> 8 & 0xFF) / 255,
                blue: CGFloat(colour & 0xFF) / 255,
                alpha: 1
            ).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.stroke()
            return true
        }
        return image
    }

    private func listFooter(_ inventory: GeometryInventory) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(footer(inventory))
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message)
                        .foregroundStyle(messageIsError ? Color.red : .secondary)
                }
            }
            .font(.caption)
            .lineLimit(2)

            Spacer()

            Button("Select All") { selectAllShown(inventory) }
                .help("Select every row shown — the whole file when nothing is filtered.")
            Button("Simplify…") { isSimplifying = true }
                .disabled(selectionCount == 0)
                .help("Reduce the triangles in the selected geometry's meshes.")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func footer(_ inventory: GeometryInventory) -> String {
        switch mode {
        case .symbols:
            let shown = symbolRows(inventory).count
            let total = inventory.items.count
            var parts = [shown == total ? plural(total, "symbol") : "\(shown) of \(total) symbols"]
            let unused = inventory.items.filter { $0.uses == 0 }.count
            if unused > 0 { parts.append("\(unused) unused") }
            if !symbolSelection.isEmpty { parts.append("\(symbolSelection.count) selected") }
            return parts.joined(separator: " · ")
        case .objects:
            let shown = objectRows(inventory).count
            let total = inventory.objects.count
            var parts = [shown == total
                ? plural(total, "object")
                : "\(shown.formatted()) of \(total.formatted()) objects"]
            if !objectSelection.isEmpty { parts.append("\(objectSelection.count.formatted()) selected") }
            return parts.joined(separator: " · ")
        }
    }

    private func selectAllShown(_ inventory: GeometryInventory) {
        switch mode {
        case .symbols: symbolSelection = Set(symbolRows(inventory).map(\.id))
        case .objects: objectSelection = Set(objectRows(inventory).map(\.id))
        }
    }

    private var selectionCount: Int {
        mode == .symbols ? symbolSelection.count : objectSelection.count
    }

    /// "3 symbols", "Slick Super Beam 3.0m".
    private var selectionDescription: String {
        guard let inventory = loaded?.inventory else { return "" }
        switch mode {
        case .symbols:
            if symbolSelection.count == 1, let item = inventory.items.first(where: { symbolSelection.contains($0.id) }) {
                return "“\(item.name)”"
            }
            return symbolSelection.count == inventory.items.count
                ? "all \(plural(symbolSelection.count, "symbol"))"
                : plural(symbolSelection.count, "symbol")
        case .objects:
            if objectSelection.count == 1,
               let object = inventory.objects.first(where: { objectSelection.contains($0.id) }) {
                return "“\(object.name)”"
            }
            return objectSelection.count == inventory.objects.count
                ? "all \(plural(objectSelection.count, "object"))"
                : plural(objectSelection.count, "object")
        }
    }

    // MARK: - The selected item

    private var previewKey: PreviewKey {
        PreviewKey(
            mode: mode,
            symbol: mode == .symbols && symbolSelection.count == 1 ? symbolSelection.first : nil,
            library: loaded.map { ObjectIdentifier($0.library) })
    }

    @ViewBuilder
    private func detail(_ inventory: GeometryInventory) -> some View {
        switch (mode, selectionCount) {
        case (.objects, _):
            objectsDetail(inventory)
        case (_, 0):
            placeholder("Pick a symbol to see it.")
        case (.symbols, 1):
            if let item = inventory.items.first(where: { symbolSelection.contains($0.id) }) {
                previewPane(info: symbolInfo(item), name: item.name)
            }
        default:
            multipleSelection(inventory)
        }
    }

    private func previewPane(info: some View, name: String) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: SymbolSceneView.background)
                if let preview {
                    SymbolSceneView(preview: preview)
                        .id(previewKey)
                } else if isBuilding {
                    ProgressView()
                } else {
                    Text("No readable meshes.")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                info
                Text(previewFacts)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                exportMenu(disabled: preview == nil || isBuilding) { format in
                    if let preview { export(name: name, node: preview.node, as: format) }
                }
                .padding(12)
            }
        }
    }

    private func symbolInfo(_ item: GeometryInventory.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.trailing, 110)
            Text(item.uses == 0 ? "Unused" : "Used \(plural(item.uses, "time"))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.uses == 0 ? .secondary : .primary)
            if !item.usage.isEmpty {
                Text(item.usage.map { "\($0.count) \($0.label)" }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(contents(of: item) + " · " + item.id.uppercased())
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func contents(of item: GeometryInventory.Item) -> String {
        var counts = [plural(item.meshCount, "mesh", "meshes")]
        if item.nestedSymbolCount > 0 { counts.append(plural(item.nestedSymbolCount, "nested symbol")) }
        return counts.joined(separator: " · ")
    }

    private var previewFacts: String {
        guard let preview, !isBuilding else { return " " }
        let (low, high) = preview.boundingBox
        var parts = [
            // Scene space is Y up, so depth is Z.
            String(format: "%.2f W × %.2f D × %.2f H m",
                   Double(high.x - low.x), Double(high.z - low.z), Double(high.y - low.y)),
            plural(preview.triangleCount, "triangle"),
        ]
        if preview.missingMeshCount > 0 { parts.append("\(preview.missingMeshCount) missing meshes") }
        return parts.joined(separator: " · ")
    }

    private func exportMenu(
        disabled: Bool = false, action: @escaping (MVRGeometryExport.Format) -> Void
    ) -> some View {
        Menu {
            ForEach(Self.exportFormats) { format in
                Button("\(format.label) (.\(format.fileExtension))") { action(format) }
                    .help(format.detail)
            }
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(disabled)
        .help("Save this as a 3D file.")
    }

    // MARK: - Objects

    /// The whole scene with the selection lit up, and its settings under it.
    private func objectsDetail(_ inventory: GeometryInventory) -> some View {
        let selected = inventory.objects.filter { objectSelection.contains($0.id) }
        return VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Color(nsColor: SymbolSceneView.background)
                if let scene, scene.node != nil {
                    ObjectSceneView(
                        scene: scene, highlight: highlight,
                        focusRequest: focusRequest, fitAllRequest: fitAllRequest
                    ) { key in
                        reveal(key, in: inventory)
                    }
                    Button("Fit All") { fitAllRequest += 1 }
                        .controlSize(.small)
                        .padding(8)
                        .help("Show the whole scene.")
                } else if scene != nil {
                    Text("No scene geometry to show.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading the scene…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            Group {
                if selected.count == 1, let object = selected.first {
                    ObjectSettings(
                        object: object,
                        layers: document.availableLayers,
                        onRename: { renameObject(object, to: $0) },
                        onMove: { moveObjects([object.id], toLayer: $0) },
                        onPosition: { moveObject(object, to: $0) },
                        exportMenu: exportMenu { format in exportObject(object, as: format) })
                    .id(object)
                } else if selected.count > 1 {
                    multipleObjects(selected)
                } else {
                    Text("Click an object in the list or in the scene.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 150)
        }
    }

    /// Selects an object clicked in the scene and scrolls the list to it,
    /// clearing a filter that would hide it.
    private func reveal(_ key: String, in inventory: GeometryInventory) {
        objectSelection = [key]
        if !objectRows(inventory).contains(where: { $0.id == key }) {
            kindFilter = nil
            filterText = ""
        }
        // A beat for the table to take the new rows before it's scrolled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let rows = objectRows(inventory)
            if let row = rows.firstIndex(where: { $0.id == key }) {
                SingleEditView.scrollTableToRow(row, rowCount: rows.count)
            }
        }
    }

    private func multipleObjects(_ selected: [GeometryInventory.Object]) -> some View {
        let containers = selected.filter(\.holdsFixtures).count
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(plural(selected.count, "object")) selected")
                .font(.headline)
            Menu("Move to Layer") {
                ForEach(document.availableLayers) { layer in
                    Button(layer.name) {
                        moveObjects(Set(selected.map(\.id)), toLayer: layer.uuid)
                    }
                }
            }
            .fixedSize()
            if containers > 0 {
                Text("\(plural(containers, "object")) holding fixtures will stay where \(containers == 1 ? "it is" : "they are").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Simplify them with the button under the list, or right-click to delete them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func renameObject(_ object: GeometryInventory.Object, to name: String) {
        document.renameGeometryObject(object.id, to: name)
    }

    private func moveObjects(_ keys: Set<String>, toLayer layerUUID: String) {
        let layer = document.availableLayers.first { $0.uuid.lowercased() == layerUUID.lowercased() }
        document.moveGeometryObjects(keys, toLayer: layerUUID)
        report("Moved \(keys.count == 1 ? "it" : plural(keys.count, "object")) to “\(layer?.name ?? "the layer")”.")
    }

    private func moveObject(_ object: GeometryInventory.Object, to position: SIMD3<Double>) {
        document.setGeometryObjectPosition(object.id, to: position)
    }

    /// Built in its own space on demand: the scene shows it where it
    /// stands, which isn't what an export wants.
    private func exportObject(_ object: GeometryInventory.Object, as format: MVRGeometryExport.Format) {
        guard let library = loaded?.library else { return }
        Task {
            guard let built = await library.preview(object: object.id) else {
                report("“\(object.name)” has no meshes to export.", isError: true)
                return
            }
            export(name: object.name, node: built.node, as: format)
        }
    }

    private func multipleSelection(_ inventory: GeometryInventory) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(selectionDescription.prefix(1).uppercased() + selectionDescription.dropFirst() + " selected")
                .font(.headline)
            if mode == .symbols {
                let chosen = inventory.items.filter { symbolSelection.contains($0.id) }
                Text("Placed \(plural(chosen.reduce(0) { $0 + $1.uses }, "time")) in all.")
                    .foregroundStyle(.secondary)
            }
            Text("Simplify them with the button under the list, or right-click to delete them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Delete

    /// Straight away, as the fixture table's ✕ does — undo puts it back.
    /// A symbol takes its placements with it, and any object they leave
    /// with no geometry.
    private func deleteSymbols(_ ids: Set<String>) {
        let names = loaded?.inventory.items.filter { ids.contains($0.id) }.map(\.name) ?? []
        document.deleteSymbols(ids)
        symbolSelection.subtract(ids)
        report(names.count == 1 ? "Deleted “\(names[0])”." : "Deleted \(plural(ids.count, "symbol")).")
    }

    /// An object holding fixtures keeps them and only loses its geometry.
    private func deleteObjects(_ keys: Set<String>) {
        let names = loaded?.inventory.objects.filter { keys.contains($0.id) }.map(\.name) ?? []
        document.deleteGeometryObjects(keys)
        objectSelection.subtract(keys)
        report(names.count == 1 ? "Deleted “\(names[0])”." : "Deleted \(plural(keys.count, "object")).")
    }

    // MARK: - Simplify

    private func finishSimplify(_ result: MVRSceneGeometryLoader.SimplifyResult) {
        guard !result.files.isEmpty else {
            report("Nothing to simplify: the meshes are already as small as they go.")
            return
        }
        document.replaceMeshFiles(result.files)
        let saved = result.trianglesBefore - result.trianglesAfter
        report("Simplified \(plural(result.files.count, "mesh", "meshes")): "
            + "\(result.trianglesBefore.formatted()) → \(result.trianglesAfter.formatted()) triangles "
            + "(\(saved.formatted()) fewer).")
    }

    // MARK: - Export

    /// Writes the item in its own space — its insertion point at the
    /// origin — so it drops into another package ready to place, not
    /// wherever the file put it.
    private func export(name: String, node: SCNNode, as format: MVRGeometryExport.Format) {
        let panel = NSSavePanel()
        let fileName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.prepareForExport(named: fileName, fileExtension: format.fileExtension)
        panel.canCreateDirectories = true
        panel.title = "Export \(name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // A clone, unattached: the shown node sits under the preview's
            // centring offset, which the exporters' world transforms would
            // otherwise bake into every vertex.
            let summary = try MVRGeometryExport.export(
                items: [MVRGeometryExport.ExportItem(node: node.clone(), name: name)],
                as: format,
                to: url.ensuringPathExtension(format.fileExtension))
            report("Exported \(summary.triangleCount.formatted()) triangles to \(format.label).")
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Work

    private func report(_ text: String, isError: Bool = false) {
        message = text
        messageIsError = isError
    }

    private func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        "\(count.formatted()) \(count == 1 ? singular : pluralForm ?? singular + "s")"
    }

    private func load() async {
        // Big files carry tens of megabytes of XML, so it's read off the
        // main thread.
        guard let source = document.geometrySource else {
            failed = true
            return
        }
        let library = await Task.detached { MVRSceneGeometryLoader.SymbolLibrary(source: source) }.value
        guard let library else {
            failed = true
            return
        }
        let inventory = await library.inventory()
        let previous = loaded?.inventory
        loaded = Loaded(library: library, inventory: inventory)

        if previous != nil {
            // Symbols and objects keep their uuids through an edit, so
            // only what's gone drops out of the selection.
            let symbols = Set(inventory.items.map(\.id))
            symbolSelection = symbolSelection.filter(symbols.contains)
            let objects = Set(inventory.objects.map(\.id))
            objectSelection = objectSelection.filter(objects.contains)
        } else {
            if inventory.objects.isEmpty { mode = .symbols }
            if let first = inventory.items.sorted(using: symbolSort).first { symbolSelection = [first.id] }
        }
    }

    private func build(_ key: PreviewKey, from library: MVRSceneGeometryLoader.SymbolLibrary) async {
        preview = nil
        isBuilding = false
        guard let symbol = key.symbol else { return }
        isBuilding = true
        let built = await library.preview(symdef: symbol)
        // A newer pick has taken over.
        guard !Task.isCancelled else { return }
        preview = built
        isBuilding = false
    }

    private func loadTraits() async {
        traits = nil
        guard let library = loaded?.library else { return }
        let read = await library.traits()
        guard !Task.isCancelled else { return }
        traits = read
    }

    private func loadScene() async {
        guard mode == .objects, sceneRevision != document.sceneRevision,
              let source = document.geometrySource else { return }
        let revision = document.sceneRevision
        let built = await Task.detached(priority: .userInitiated) {
            MVRSceneGeometryLoader.buildGeometryNode(source: source)
        }.value
        guard !Task.isCancelled else { return }
        scene = built
        sceneRevision = revision
    }

    /// A highlight of every object of a common material is still worth
    /// seeing; past this many, building it would just be slow.
    private static let highlightLimit = 10_000

    private func buildHighlight() async {
        let keys = objectSelection
        guard mode == .objects, let library = loaded?.library,
              !keys.isEmpty, keys.count <= Self.highlightLimit else {
            highlight = nil
            return
        }
        let built = await library.highlight(objects: keys)
        guard !Task.isCancelled else { return }
        highlight = built
        if keys != focusedSelection {
            focusedSelection = keys
            focusRequest += 1
        }
    }
}

/// How much to simplify, what that comes to, and the run itself.
private struct SimplifySheet: View {
    let library: MVRSceneGeometryLoader.SymbolLibrary
    /// "3 symbols", "“Kara”".
    let subject: String
    let symbols: Set<String>
    let objects: Set<String>
    /// The objects' meshes may come from symbols used elsewhere too.
    let sharedThroughSymbols: Bool
    let onFinish: (MVRSceneGeometryLoader.SimplifyResult?) -> Void

    @AppStorage("geometrySimplifyKeep") private var keep = 0.5
    @State private var meshKeys: Set<String>?
    @State private var triangles: Int?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Simplify \(subject)")
                .font(.headline)

            Group {
                if let meshKeys, let triangles {
                    Text("\(meshKeys.count.formatted()) \(meshKeys.count == 1 ? "mesh" : "meshes"), \(triangles.formatted()) triangles.")
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Counting triangles…")
                    }
                }
            }
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Keep")
                    Slider(value: $keep, in: 0.1...0.9, step: 0.05)
                    Text("\(Int((keep * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                if let triangles {
                    Text("About \(Int(Double(triangles) * keep).formatted()) triangles afterwards.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Thin parts such as truss tubes start to break up below about 30%.")
                Text("Meshes of \(MeshSimplifier.minimumTriangles) triangles or fewer are left alone.")
                if sharedThroughSymbols {
                    Text("A mesh an object takes from a symbol changes everywhere that symbol is used.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text("Simplifying…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .disabled(isRunning)
                Button("Simplify") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || (meshKeys?.isEmpty ?? true))
            }
        }
        .padding(24)
        .frame(width: 440)
        .task {
            let keys = await library.meshKeys(symdefs: symbols)
                .union(await library.meshKeys(objects: objects))
            meshKeys = keys
            triangles = await library.triangleCount(meshKeys: keys)
        }
    }

    private func run() async {
        guard let meshKeys else { return }
        isRunning = true
        let result = await library.simplify(meshKeys: meshKeys, keeping: keep)
        isRunning = false
        onFinish(result)
    }
}

/// One symbol or object on its own, framed to fit, turned by dragging.
private struct SymbolSceneView: NSViewRepresentable {
    let preview: MVRSceneGeometryLoader.SymbolPreview

    static let background = NSColor(calibratedWhite: 0.16, alpha: 1)

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = Self.background
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true

        let scene = SCNScene()
        let (low, high) = preview.boundingBox
        let centre = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
        let holder = SCNNode()
        holder.position = SCNVector3(-centre.x, -centre.y, -centre.z)
        holder.addChildNode(preview.node)
        scene.rootNode.addChildNode(holder)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 400
        scene.rootNode.addChildNode(ambient)

        // Far enough back for the whole bounding sphere to fit the field of
        // view, from a three-quarter view above the front.
        let size = SCNVector3(high.x - low.x, high.y - low.y, high.z - low.z)
        let radius = max(sqrt(size.x * size.x + size.y * size.y + size.z * size.z) / 2, 0.01)
        let fieldOfView: CGFloat = 35
        let distance = radius / sin(fieldOfView / 2 * .pi / 180) * 1.1
        let yaw: CGFloat = .pi / 5
        let pitch: CGFloat = .pi / 8

        let camera = SCNCamera()
        camera.fieldOfView = fieldOfView
        camera.zNear = Double(distance * 0.01)
        camera.zFar = Double(distance * 20)
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(
            distance * cos(pitch) * sin(yaw),
            distance * sin(pitch),
            distance * cos(pitch) * cos(yaw))
        cameraNode.eulerAngles = SCNVector3(-pitch, yaw, 0)
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        view.pointOfView = cameraNode
        view.defaultCameraController.target = SCNVector3Zero
        view.defaultCameraController.interactionMode = .orbitTurntable
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}
}

/// One object's settings: its name, layer and position, each written to
/// the file as it's committed — Return in a field, or a pick from the menu.
private struct ObjectSettings<ExportMenu: View>: View {
    let object: GeometryInventory.Object
    let layers: [MVRLayerRef]
    let onRename: (String) -> Void
    let onMove: (String) -> Void
    let onPosition: (SIMD3<Double>) -> Void
    let exportMenu: ExportMenu

    @State private var name: String
    @State private var x: String
    @State private var y: String
    @State private var z: String

    init(
        object: GeometryInventory.Object, layers: [MVRLayerRef],
        onRename: @escaping (String) -> Void, onMove: @escaping (String) -> Void,
        onPosition: @escaping (SIMD3<Double>) -> Void, exportMenu: ExportMenu
    ) {
        self.object = object
        self.layers = layers
        self.onRename = onRename
        self.onMove = onMove
        self.onPosition = onPosition
        self.exportMenu = exportMenu
        let position = object.position ?? .zero
        _name = State(initialValue: object.name == "Unnamed" ? "" : object.name)
        _x = State(initialValue: Self.format(position.x))
        _y = State(initialValue: Self.format(position.y))
        _z = State(initialValue: Self.format(position.z))
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    var body: some View {
        HStack(alignment: .top) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("Name", text: $name, prompt: Text("Unnamed"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { onRename(name) }
                        .help("Press Return to rename.")
                }
                GridRow {
                    Text("Layer").foregroundStyle(.secondary)
                    Picker("Layer", selection: Binding(
                        get: { object.layerUUID.lowercased() },
                        set: { onMove($0) })
                    ) {
                        ForEach(layers) { layer in
                            Text(layer.name).tag(layer.uuid.lowercased())
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(object.holdsFixtures)
                    .help(object.holdsFixtures
                        ? "Fixtures sit inside this object, so it stays in its layer."
                        : "Move this object to another layer.")
                }
                GridRow {
                    Text("Position").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        coordinate("X", $x)
                        coordinate("Y", $y)
                        coordinate("Z", $z)
                        Text("mm").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text(object.modelSummary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(object.modelSummary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(GeometryInventory.kindName(object.kind))
                    .font(.headline)
                exportMenu
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func coordinate(_ axis: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 3) {
            Text(axis).font(.caption).foregroundStyle(.secondary)
            TextField(axis, text: value)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 80)
                .onSubmit(commitPosition)
                .help("Press Return to move the object. Millimetres, as the file stores them.")
        }
    }

    private func commitPosition() {
        let parsed = [x, y, z].map { Double($0.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) }
        guard let px = parsed[0], let py = parsed[1], let pz = parsed[2] else { return }
        let target = SIMD3(px, py, pz)
        guard target != (object.position ?? .zero) else { return }
        onPosition(target)
    }
}

/// The whole scene, with the chosen objects drawn over it in the selection
/// colour and the camera brought to them. Drag to turn, scroll to zoom,
/// click an object to choose it.
private struct ObjectSceneView: NSViewRepresentable {
    let scene: MVRSceneGeometryLoader.LoadedGeometry
    let highlight: MVRSceneGeometryLoader.SymbolPreview?
    /// Moves when the camera should go to the highlight.
    let focusRequest: Int
    /// Moves when the camera should show everything.
    let fitAllRequest: Int
    let onPick: (String) -> Void

    final class Coordinator: NSObject {
        weak var view: SCNView?
        var onPick: (String) -> Void = { _ in }
        var keyByNodeName: [String: String] = [:]
        var sceneNode: SCNNode?
        var sceneBox: (min: SCNVector3, max: SCNVector3)?
        var highlightNode: SCNNode?
        var focusRequest = 0
        var fitAllRequest = 0

        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let view else { return }
            // AppKit's bottom-left space, the same one hitTest uses.
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: true,
            ])
            // The highlight is drawn on top but isn't an object; look past
            // it to what's underneath.
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, let key = keyByNodeName[name] {
                        onPick(key)
                        return
                    }
                    node = current.parent
                }
            }
        }

        /// Brings the box into view, from the current angle or a fresh
        /// three-quarter one.
        func frame(_ box: (min: SCNVector3, max: SCNVector3), resetAngle: Bool) {
            guard let view, let camera = view.pointOfView else { return }
            let centre = SCNVector3(
                (box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2, (box.min.z + box.max.z) / 2)
            let dx = box.max.x - box.min.x, dy = box.max.y - box.min.y, dz = box.max.z - box.min.z
            let radius = max(sqrt(dx * dx + dy * dy + dz * dz) / 2, 0.05)
            let fieldOfView = camera.camera?.fieldOfView ?? 40
            let distance = radius / sin(fieldOfView / 2 * .pi / 180) * 1.25

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.45
            if resetAngle { camera.eulerAngles = SCNVector3(-CGFloat.pi / 7, CGFloat.pi / 6, 0) }
            let front = camera.worldFront
            camera.worldPosition = SCNVector3(
                centre.x - front.x * distance, centre.y - front.y * distance, centre.z - front.z * distance)
            SCNTransaction.commit()

            // Close in on a small object without clipping it, and still
            // reach the far side of a venue.
            camera.camera?.zNear = Double(max(0.01, distance * 0.002))
            camera.camera?.zFar = Double(max(distance * 20, sceneRadius * 6))
            view.defaultCameraController.target = centre
        }

        private var sceneRadius: CGFloat {
            guard let box = sceneBox else { return 100 }
            let dx = box.max.x - box.min.x, dy = box.max.y - box.min.y, dz = box.max.z - box.min.z
            return sqrt(dx * dx + dy * dy + dz * dz) / 2
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = SymbolSceneView.background
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.defaultCameraController.interactionMode = .orbitTurntable

        let root = SCNScene()
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 400
        root.rootNode.addChildNode(ambient)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 40
        root.rootNode.addChildNode(camera)
        view.scene = root
        view.pointOfView = camera

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        view.addGestureRecognizer(click)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPick = onPick
        guard let root = view.scene?.rootNode else { return }

        if let node = scene.node, coordinator.sceneNode !== node {
            let isFirst = coordinator.sceneNode == nil
            coordinator.sceneNode?.removeFromParentNode()
            root.addChildNode(node)
            coordinator.sceneNode = node
            coordinator.sceneBox = node.boundingBox
            var keys: [String: String] = [:]
            for object in scene.objects {
                if let key = object.key { keys[object.id] = key }
            }
            coordinator.keyByNodeName = keys
            // A rebuild after an edit keeps the camera where it was.
            if isFirst, let box = coordinator.sceneBox { coordinator.frame(box, resetAngle: true) }
        }

        let newHighlight = highlight?.node
        if coordinator.highlightNode !== newHighlight {
            coordinator.highlightNode?.removeFromParentNode()
            if let newHighlight {
                Self.styleAsHighlight(newHighlight)
                root.addChildNode(newHighlight)
            }
            coordinator.highlightNode = newHighlight
        }

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            if let highlight { coordinator.frame(highlight.boundingBox, resetAngle: false) }
        }
        if coordinator.fitAllRequest != fitAllRequest {
            coordinator.fitAllRequest = fitAllRequest
            if let box = coordinator.sceneBox { coordinator.frame(box, resetAngle: true) }
        }
    }

    /// The selection colour, lit from within and drawn over everything,
    /// so a chosen object shows even behind a wall or inside a truss run.
    private static func styleAsHighlight(_ node: SCNNode) {
        node.enumerateHierarchy { child, _ in
            child.renderingOrder = 1000
            guard let geometry = child.geometry else { return }
            let material = SCNMaterial()
            material.diffuse.contents = MVRSceneGeometryLoader.selectedColor
            material.emission.contents = MVRSceneGeometryLoader.selectedColor.withAlphaComponent(0.6)
            material.lightingModel = .lambert
            material.isDoubleSided = true
            material.transparency = 0.85
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            geometry.materials = [material]
        }
    }
}
