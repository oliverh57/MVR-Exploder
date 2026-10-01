import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SingleEditView: View {
    let onBack: () -> Void

    @StateObject private var document = MVRDocument()

    @State private var isTargeted = false
    @State private var errorMessage: String?

    // Drag-and-drop → ask which field holds the fixture ID before loading,
    // but only when the file itself is actually ambiguous about it.
    @State private var pendingDropURL: URL?
    @State private var showFieldChoiceDialog = false

    @State private var showImportSummary = false
    @State private var importSummaryMessage = ""

    @State private var showOffsetSheet = false
    @State private var offsetInput = ""

    @State private var showUniverseOffsetSheet = false
    @State private var universeOffsetInput = ""

    @State private var showExportSheet = false
    @State private var includeSceneGeometry = true
    @State private var assignLayersByFixtureType = false
    @State private var replaceAllWithDummyGDTFs = false
    @State private var cleanupEmptyClassesAndLayers = false

    @State private var showPatchPDFLayoutChoice = false

    @State private var showRegenerateUUIDConfirm = false
    @State private var showRemoveUnpatchedConfirm = false
    @State private var showFixtureIDMap = false
    @State private var showPatchCheck = false
    @State private var autoIDSession: AutoIDSession?
    @StateObject private var viewer3D = Fixture3DWindowPresenter()
    @State private var selectedFixtureIDs: Set<String> = []
    @State private var recentlyJumpedIDs: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<MVRFixture>] = []
    @State private var filterField: FixtureFilterField = .name
    @State private var filterText = ""

    /// Any field differing from the loaded file — not just the three that
    /// existed before name, layer and mode became editable, or a rename
    /// would leave the reset control greyed out with changes pending.
    private var hasEdits: Bool {
        document.fixtures.contains { fixture in
            MVRFixtureField.allCases.contains { fixture.isEdited($0) }
        }
    }

    private func unpatchedCount(_ criteria: MVRFixture.UnpatchedCriteria) -> Int {
        document.fixtures.filter { $0.isUnpatched(by: criteria) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if document.fixtures.isEmpty {
                dropZone
            } else {
                topBar
                Divider()
                filterBar
                Divider()
                fixturesTable
                Divider()
                bottomBar
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .confirmationDialog(
            "Which field holds each fixture's ID in this file?",
            isPresented: $showFieldChoiceDialog,
            titleVisibility: .visible
        ) {
            Button("FixtureID") { loadPendingDrop(idFieldName: "FixtureID") }
            Button("UnitNumber (Channel)") { loadPendingDrop(idFieldName: "UnitNumber") }
            Button("Cancel", role: .cancel) { pendingDropURL = nil }
        } message: {
            Text("This file has real data in both fields, so it can't be inferred automatically — most MVR exporters use FixtureID, some use UnitNumber (also called Channel on some consoles).")
        }
        .alert("Import Successful", isPresented: $showImportSummary) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importSummaryMessage)
        }
        .sheet(isPresented: $showOffsetSheet) {
            offsetSheet
        }
        .sheet(isPresented: $showUniverseOffsetSheet) {
            universeOffsetSheet
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheet
        }
        .sheet(item: $autoIDSession) { session in
            AutoIDView(
                session: session,
                onCancel: { autoIDSession = nil },
                onApply: {
                    session.apply(to: document)
                    autoIDSession = nil
                })
        }
        .sheet(isPresented: $showPatchCheck) {
            PatchCheckView(
                document: document,
                onClose: { showPatchCheck = false },
                onSelectFixtures: { revealFixtures(ids: $0) })
        }
        .sheet(isPresented: $showFixtureIDMap) {
            FixtureIDMapView(fixtures: document.fixtures) {
                showFixtureIDMap = false
            } onSelectID: { fixtureID in
                jumpToFixture(withID: fixtureID)
            }
        }
    }

    /// Reveals every fixture carrying this Fixture ID — so a clash
    /// highlights both rows, not just the first.
    private func jumpToFixture(withID fixtureID: Int) {
        let matches = document.fixtures.filter { ($0.currentFixtureID ?? 0) == fixtureID }
        showFixtureIDMap = false
        guard !matches.isEmpty else { return }
        revealFixtures(ids: Set(matches.map(\.id)))
    }

    /// Scrolls the table to these fixtures and marks them.
    ///
    /// Clears any active filter first, so a target row can't be sitting
    /// hidden behind it. Scrolling itself is driven by selection: `Table`
    /// has no programmatic scroll-to-row API, but it does scroll to follow
    /// its selection binding — and only on a genuine *change* to that
    /// binding, so selection and the flash set are cleared and then set a
    /// beat later. Without that explicit empty→filled transition, revealing
    /// the same fixture twice (and, in practice, sometimes any fixture after
    /// the first) silently does nothing.
    private func revealFixtures(ids: Set<String>) {
        guard !ids.isEmpty else { return }

        filterText = ""
        selectedFixtureIDs = []
        recentlyJumpedIDs = []

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            selectedFixtureIDs = ids
            withAnimation(.easeInOut(duration: 0.25).repeatCount(5, autoreverses: true)) {
                recentlyJumpedIDs = ids
            }
            // Selection alone is not enough to guarantee the row is on
            // screen, so scroll to it explicitly once SwiftUI has had a pass
            // to apply the cleared filter and new selection.
            let rows = sortedFixtures
            if let row = rows.firstIndex(where: { ids.contains($0.id) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    Self.scrollTableToRow(row, rowCount: rows.count)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.easeOut(duration: 1.0)) {
                    recentlyJumpedIDs.subtract(ids)
                }
            }
        }
    }

    /// Scrolls the fixture table to a row.
    ///
    /// SwiftUI's `Table` has no programmatic scroll-to-row API; it scrolls
    /// to follow its selection binding, but that's undocumented and doesn't
    /// fire dependably — which leaves "reveal this fixture" looking broken
    /// whenever the target row is off screen. On macOS `Table` is an
    /// `NSTableView` underneath, so this finds it and scrolls it directly.
    /// The row count is used to pick the right table out of whatever windows
    /// are open, and everything here is best-effort: if the view tree ever
    /// stops looking like this, the selection and flash still happen.
    private static func scrollTableToRow(_ row: Int, rowCount: Int) {
        func firstTableView(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let found = firstTableView(in: subview) { return found }
            }
            return nil
        }

        for window in NSApp.windows {
            guard
                let content = window.contentView,
                let table = firstTableView(in: content),
                table.numberOfRows == rowCount,
                row < table.numberOfRows
            else { continue }
            table.scrollRowToVisible(row)
            return
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Button("← Mode") { onBack() }
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drag an .mvr file here")
                .font(.title2)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    private var topBar: some View {
        HStack {
            Button("← Mode") { onBack() }

            Button("Clear") {
                document.clear()
                errorMessage = nil
            }

            Text(document.fileName)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Smart Auto ID…") {
                autoIDSession = AutoIDSession(
                    fixtures: document.fixtures,
                    storedNames: document.groupNames,
                    session: document.autoIDSession)
            }
            .disabled(document.fixtures.isEmpty)

            Button("Fixture ID Map…") {
                showFixtureIDMap = true
            }
            .disabled(document.fixtures.isEmpty)

            Button("Patch Check…") {
                showPatchCheck = true
            }
            .disabled(document.fixtures.isEmpty)

            Button("View 3D…") {
                viewer3D.present(
                    fixtures: document.fixtures,
                    document: document,
                    fileName: document.fileName
                ) { fixtureID in
                    revealFixtures(ids: [fixtureID])
                }
            }
            .disabled(document.fixtures.isEmpty)

            Button("Export Patch PDF…") {
                showPatchPDFLayoutChoice = true
            }
            .disabled(document.fixtures.isEmpty)
            .confirmationDialog(
                "Lay out the patch PDF by…",
                isPresented: $showPatchPDFLayoutChoice,
                titleVisibility: .visible
            ) {
                Button("Fixture Type") { presentSavePanelAndExportPatchPDF(layout: .byFixtureType) }
                Button("Fixture ID") { presentSavePanelAndExportPatchPDF(layout: .byFixtureID) }
                Button("Cancel", role: .cancel) {}
            }

            Button("Export MVR…") {
                showExportSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(10)
    }

    private var filteredFixtures: [MVRFixture] {
        document.fixtures.filter { $0.matchesFilter(filterText, field: filterField) }
    }

    private var sortedFixtures: [MVRFixture] {
        filteredFixtures.sorted(using: sortOrder)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)

            Text("Search by:")
                .foregroundStyle(.secondary)

            Picker("Filter field", selection: $filterField) {
                ForEach(FixtureFilterField.allCases) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField("Filter…", text: $filterText)
                .textFieldStyle(.roundedBorder)

            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Text("\(sortedFixtures.count) of \(document.fixtures.count)")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var fixturesTable: some View {
        Table(sortedFixtures, selection: $selectedFixtureIDs, sortOrder: $sortOrder) {
            TableColumn("") { fixture in
                DeleteRowButton {
                    document.deleteFixture(withID: fixture.id)
                }
            }
            .width(28)

            TableColumn("Name", sortUsing: KeyPathComparator(\.name)) { fixture in
                cell(fixture) {
                    editable(fixture, .name, text: fixture.name) {
                        Text(fixture.name)
                            .foregroundStyle(fixture.isNameEdited ? .blue : .primary)
                    }
                }
            }
            TableColumn("Fixture ID", sortUsing: KeyPathComparator(\.sortableFixtureID)) { fixture in
                cell(fixture) {
                    editable(fixture, .fixtureID, text: fixture.currentFixtureID.map(String.init) ?? "") {
                        Text(fixture.currentFixtureID.map(String.init) ?? "-")
                            .foregroundStyle(fixture.isFixtureIDEdited ? .blue : .primary)
                    }
                }
            }
            TableColumn("UUID", sortUsing: KeyPathComparator(\.currentUUID)) { fixture in
                cell(fixture) {
                    editable(fixture, .uuid, text: fixture.currentUUID) {
                        UUIDCell(uuid: fixture.currentUUID, color: fixture.isUUIDEdited ? .blue : .gray)
                    }
                }
            }
            TableColumn("Layer", sortUsing: KeyPathComparator(\.layerName)) { fixture in
                cell(fixture) {
                    EditableLayerCell(
                        layerName: fixture.layerName,
                        isEdited: fixture.isLayerEdited,
                        layers: document.availableLayers,
                        onSelect: { layer in
                            document.setLayer(name: layer.name, uuid: layer.uuid, forFixtureAtID: fixture.id)
                        },
                        onReset: { document.resetField(.layer, forFixtureAtID: fixture.id) })
                }
            }
            TableColumn("Universe", sortUsing: KeyPathComparator(\.sortableUniverse)) { fixture in
                cell(fixture) {
                    editable(fixture, .universe, text: fixture.universe == "-" ? "" : fixture.universe) {
                        Text(fixture.universe)
                            .foregroundStyle(fixture.isAddressEdited ? .blue : .primary)
                    }
                }
            }
            TableColumn("Channel", sortUsing: KeyPathComparator(\.sortableChannel)) { fixture in
                cell(fixture) {
                    editable(fixture, .channel, text: fixture.channel == "-" ? "" : fixture.channel) {
                        Text(fixture.channel)
                            .foregroundStyle(fixture.isAddressEdited ? .blue : .primary)
                    }
                }
            }
            TableColumn("GDTF Spec", sortUsing: KeyPathComparator(\.gdtfSpec)) { fixture in
                cell(fixture) { Text(fixture.gdtfSpec) }
            }
            TableColumn("Mode", sortUsing: KeyPathComparator(\.mode)) { fixture in
                cell(fixture) {
                    editable(fixture, .mode, text: fixture.mode == "-" ? "" : fixture.mode) {
                        Text(fixture.mode)
                            .foregroundStyle(fixture.isModeEdited ? .blue : .primary)
                    }
                }
            }
        }
        // Right-clicking inside a selection acts on all of it; right-clicking
        // an unselected row acts on that row alone.
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Delete Fixture" : "Delete \(ids.count) Fixtures", role: .destructive) {
                    document.deleteFixtures(withIDs: ids)
                    selectedFixtureIDs.subtract(ids)
                }
            }
        }
    }

    /// Wraps a value in the hover-to-edit affordance, wiring one field to
    /// the validation and setter that belong to it.
    private func editable<Content: View>(
        _ fixture: MVRFixture,
        _ field: MVRFixtureField,
        text: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        EditableCell(
            isEdited: fixture.isEdited(field),
            editText: text,
            validate: { Self.validate($0, for: field) },
            onCommit: { apply($0, to: field, of: fixture) },
            onReset: { document.resetField(field, forFixtureAtID: fixture.id) },
            content: content)
    }

    private static func validate(_ value: String, for field: MVRFixtureField) -> String? {
        switch field {
        case .name, .mode:
            return value.isEmpty ? "Cannot be empty." : nil
        case .uuid:
            return value.isEmpty ? "Cannot be empty." : nil
        case .fixtureID:
            guard let number = Int(value) else { return "Must be a whole number." }
            return number < 0 ? "Cannot be negative." : nil
        case .universe:
            guard let number = Int(value) else { return "Must be a whole number." }
            return number < 1 ? "Universe starts at 1." : nil
        case .channel:
            guard let number = Int(value) else { return "Must be a whole number." }
            return (1...512).contains(number) ? nil : "Channel must be between 1 and 512."
        case .layer:
            return nil
        }
    }

    /// Writes a validated value back through the document.
    ///
    /// Universe and Channel are two views of one absolute address, so each
    /// is recombined with the other's current value rather than written
    /// directly. A fixture with no patch at all is treated as universe 1 /
    /// channel 1 so the first edit has somewhere to start from.
    private func apply(_ value: String, to field: MVRFixtureField, of fixture: MVRFixture) {
        switch field {
        case .name:
            document.setName(value, forFixtureAtID: fixture.id)
        case .uuid:
            document.setUUID(value, forFixtureAtID: fixture.id)
        case .mode:
            document.setGDTFMode(value, forFixtureAtID: fixture.id)
        case .fixtureID:
            guard let number = Int(value) else { return }
            document.setFixtureID(number, forFixtureAtID: fixture.id)
        case .universe, .channel:
            guard let number = Int(value) else { return }
            let existing = fixture.currentAddress.map(MVRFixture.universeAndChannel(fromAbsoluteAddress:))
            let universe = field == .universe ? number : (existing?.universe ?? 1)
            let channel = field == .channel ? number : (existing?.channel ?? 1)
            document.setAddress((universe - 1) * 512 + channel, forFixtureAtID: fixture.id)
        case .layer:
            break
        }
    }

    /// Wraps a column's content so it fills the cell width and picks up a
    /// bright flash when this fixture was just jumped to from the Fixture
    /// ID Map. Entry pulses a few times (see jumpToFixture) before settling
    /// into a solid highlight, then fades out smoothly — deliberately loud,
    /// since a static tint was too easy to miss.
    private func cell<Content: View>(_ fixture: MVRFixture, @ViewBuilder content: () -> Content) -> some View {
        let isFlashing = recentlyJumpedIDs.contains(fixture.id)
        return content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .background(isFlashing ? Color.orange.opacity(0.85) : Color.clear)
            .overlay(
                Rectangle()
                    .stroke(isFlashing ? Color.red : Color.clear, lineWidth: 3)
            )
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }

            Spacer()

            Text("\(document.fixtures.count) fixtures")
                .foregroundStyle(.secondary)

            if hasEdits {
                Button("Reset Changes") {
                    document.resetChanges()
                }
            }

            Button("Offset Fixture IDs…") {
                offsetInput = ""
                showOffsetSheet = true
            }

            Button("Offset Universe…") {
                universeOffsetInput = ""
                showUniverseOffsetSheet = true
            }

            Button("Generate New UUIDs…") {
                showRegenerateUUIDConfirm = true
            }
            .confirmationDialog(
                "Generate new UUIDs for all \(document.fixtures.count) fixtures?",
                isPresented: $showRegenerateUUIDConfirm,
                titleVisibility: .visible
            ) {
                Button("Generate New UUIDs", role: .destructive) {
                    document.generateNewUUIDs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This replaces every fixture's uuid. Use Reset Changes to undo before exporting.")
            }

            Button("Remove All Non-Patched Fixtures…") {
                showRemoveUnpatchedConfirm = true
            }
            .disabled(document.fixtures.isEmpty)
            .confirmationDialog(
                "What counts as a non-patched fixture?",
                isPresented: $showRemoveUnpatchedConfirm,
                titleVisibility: .visible
            ) {
                Button("No DMX Patch — \(unpatchedCount(.noDMXPatch)) fixture(s)", role: .destructive) {
                    document.removeFixtures(matching: .noDMXPatch)
                }
                Button("No Fixture ID — \(unpatchedCount(.noFixtureID)) fixture(s)", role: .destructive) {
                    document.removeFixtures(matching: .noFixtureID)
                }
                Button("Both — \(unpatchedCount(.both)) fixture(s)", role: .destructive) {
                    document.removeFixtures(matching: .both)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("No DMX Patch means Universe 1, Address 0. No Fixture ID means Fixture ID 0. Choose which definition to delete by.")
            }
        }
        .padding(10)
    }

    private var offsetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Offset Fixture IDs")
                .font(.headline)
            Text("Enter an amount to add to every fixture's ID. Use a negative number to decrease.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Offset amount", text: $offsetInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            HStack {
                Spacer()
                Button("Cancel") { showOffsetSheet = false }
                Button("Apply") {
                    if let offset = Int(offsetInput) {
                        document.applyFixtureIDOffset(offset)
                    }
                    showOffsetSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Int(offsetInput) == nil)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private var universeOffsetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Offset Universe")
                .font(.headline)
            Text("Enter a number of universes to shift every fixture's DMX address by. Use a negative number to decrease.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Offset amount", text: $universeOffsetInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            HStack {
                Spacer()
                Button("Cancel") { showUniverseOffsetSheet = false }
                Button("Apply") {
                    if let offset = Int(universeOffsetInput) {
                        document.applyUniverseOffset(offset)
                    }
                    showUniverseOffsetSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Int(universeOffsetInput) == nil)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export MVR")
                .font(.headline)

            Toggle("Include scene geometry", isOn: $includeSceneGeometry)
            Text("When off, the exported file keeps only fixture and GDTF data — 3D venue geometry (files and <SceneObject> entries) is left out.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Assign fixture layers by type", isOn: $assignLayersByFixtureType)
            Text("Groups fixtures into layers named after their GDTF spec. Everything else moves into a layer named \"NONE\".")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Replace all fixtures with dummy GDTFs", isOn: $replaceAllWithDummyGDTFs)
            Text("Swaps every fixture's GDTF for a generated placeholder, even if the real one is present. Fixtures already missing a GDTF always get a placeholder regardless of this setting.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Cleanup empty classes and layers", isOn: $cleanupEmptyClassesAndLayers)
            Text("Removes any layer with no objects in it, and any class no object references.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { showExportSheet = false }
                Button("Choose Location & Export…") {
                    showExportSheet = false
                    presentSavePanelAndExport()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard
                let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil),
                url.pathExtension.lowercased() == "mvr"
            else {
                DispatchQueue.main.async {
                    self.errorMessage = "Please drop a valid .mvr file."
                }
                return
            }

            DispatchQueue.main.async {
                self.pendingDropURL = url

                // Only ask when the file genuinely doesn't say which field
                // is real: if just one of FixtureID/UnitNumber actually has
                // non-zero values, that's the answer, and asking anyway
                // would just be friction for no reason.
                switch MVRDocument.detectIDField(at: url) {
                case .determined(let fieldName):
                    self.loadPendingDrop(idFieldName: fieldName)
                case .ambiguous:
                    self.showFieldChoiceDialog = true
                }
            }
        }

        return true
    }

    private func loadPendingDrop(idFieldName: String) {
        guard let url = pendingDropURL else { return }
        pendingDropURL = nil

        do {
            try document.load(from: url, idFieldName: idFieldName)
            errorMessage = nil
            presentImportSummary(idFieldName: idFieldName)
        } catch {
            errorMessage = "Failed to parse MVR file: \(error.localizedDescription)"
        }
    }

    /// Builds and shows the post-import summary — fixture count, which ID
    /// field was used (and whether that was auto-detected or picked by the
    /// user), and a couple of stats worth knowing right away.
    private func presentImportSummary(idFieldName: String) {
        let fixtures = document.fixtures
        let total = fixtures.count
        let typeCount = Set(fixtures.map(\.gdtfSpec)).count
        let noPatchCount = fixtures.filter { $0.hasNoDMXPatch }.count
        let noIDCount = fixtures.filter { $0.hasNoFixtureID }.count
        let universeCount = Set(
            fixtures.compactMap { fixture in
                fixture.currentAddress.map { MVRFixture.universeAndChannel(fromAbsoluteAddress: $0).universe }
            }
        ).count

        let fieldLabel = idFieldName == "UnitNumber" ? "UnitNumber (Channel)" : "FixtureID"
        var lines = ["\(total) fixture\(total == 1 ? "" : "s") imported using \(fieldLabel) as the ID field."]

        var stats: [String] = []
        stats.append("\(typeCount) fixture type\(typeCount == 1 ? "" : "s")")
        if universeCount > 0 {
            stats.append("\(universeCount) universe\(universeCount == 1 ? "" : "s")")
        }
        lines.append(stats.joined(separator: ", ") + ".")

        if noPatchCount > 0 {
            lines.append("\(noPatchCount) fixture\(noPatchCount == 1 ? "" : "s") with no DMX patch.")
        }
        if noIDCount > 0 {
            lines.append("\(noIDCount) fixture\(noIDCount == 1 ? "" : "s") with no \(fieldLabel).")
        }

        importSummaryMessage = lines.joined(separator: "\n")
        showImportSummary = true
    }

    private func presentSavePanelAndExport() {
        let panel = NSSavePanel()
        let baseName = (document.fileName as NSString).deletingPathExtension
        panel.prepareForExport(named: "\(baseName)_edited", fileExtension: "mvr")

        let options = MVRExportOptions(
            includeSceneGeometry: includeSceneGeometry,
            assignLayersByFixtureType: assignLayersByFixtureType,
            replaceAllWithDummyGDTFs: replaceAllWithDummyGDTFs,
            cleanupEmptyClassesAndLayers: cleanupEmptyClassesAndLayers
        )

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }
            do {
                try MVRExporter.export(document, to: destinationURL.ensuringPathExtension("mvr"), options: options)
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func presentSavePanelAndExportPatchPDF(layout: PatchPDFLayout) {
        let panel = NSSavePanel()
        let baseName = (document.fileName as NSString).deletingPathExtension
        panel.prepareForExport(named: "\(baseName)_patch", fileExtension: "pdf")

        let fixtures = document.fixtures
        let title = "Patch List — \(document.fileName)"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }
            do {
                try MVRPatchPDFExporter.export(fixtures: fixtures, layout: layout, documentTitle: title, to: destinationURL.ensuringPathExtension("pdf"))
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Patch PDF export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    SingleEditView(onBack: {})
}
