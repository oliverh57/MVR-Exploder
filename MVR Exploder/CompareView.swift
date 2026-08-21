import SwiftUI
import UniformTypeIdentifiers
import AppKit

private enum DropSide {
    case left
    case right
}

private enum CopyDirection {
    case aToB
    case bToA
}

struct CompareView: View {
    let onBack: () -> Void

    @StateObject private var leftDocument = MVRDocument()
    @StateObject private var rightDocument = MVRDocument()

    @State private var leftError: String?
    @State private var rightError: String?
    @State private var isLeftTargeted = false
    @State private var isRightTargeted = false

    // Drag-and-drop → ask which field holds the fixture ID before loading.
    @State private var pendingDrop: (side: DropSide, url: URL)?
    @State private var showFieldChoiceDialog = false

    @State private var matchMode: MatchMode = .uuid
    @State private var showFileAColumns = true
    @State private var showFileBColumns = true
    @State private var sortOrder: [KeyPathComparator<MVRComparisonRow>] = []
    @State private var filterField: FixtureFilterField = .name
    @State private var filterText = ""

    @State private var showCopyAttributesSheet = false
    @State private var copyDirection: CopyDirection = .aToB
    @State private var copyID = true
    @State private var copyName = false
    @State private var copyPatch = false
    @State private var copyLayer = false
    @State private var copyClass = false
    @State private var copy3D = false
    @State private var copyGDTF = false

    @State private var showExportSheet = false
    @State private var exportSide: DropSide?
    @State private var includeSceneGeometry = true
    @State private var assignLayersByFixtureType = false
    @State private var replaceAllWithDummyGDTFs = false
    @State private var cleanupEmptyClassesAndLayers = false

    @State private var showRemoveUnpatchedConfirm = false

    private var comparisonRows: [MVRComparisonRow] {
        MVRComparator.compare(left: leftDocument.fixtures, right: rightDocument.fixtures, matchMode: matchMode)
    }

    private var matchedCount: Int {
        comparisonRows.filter { $0.status == .matched }.count
    }

    private func unpatchedCount(_ criteria: MVRFixture.UnpatchedCriteria) -> Int {
        leftDocument.fixtures.filter { $0.isUnpatched(by: criteria) }.count
            + rightDocument.fixtures.filter { $0.isUnpatched(by: criteria) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            fileHeaderBar
            Divider()
            filterBar
            Divider()
            comparisonTable
            Divider()
            bottomBar
        }
        .confirmationDialog(
            "Which field holds each fixture's ID in this file?",
            isPresented: $showFieldChoiceDialog,
            titleVisibility: .visible
        ) {
            Button("FixtureID") { loadPendingDrop(idFieldName: "FixtureID") }
            Button("UnitNumber") { loadPendingDrop(idFieldName: "UnitNumber") }
            Button("Cancel", role: .cancel) { pendingDrop = nil }
        } message: {
            Text("Most MVR exporters use <FixtureID>, but some use <UnitNumber> instead.")
        }
        .sheet(isPresented: $showCopyAttributesSheet) {
            copyAttributesSheet
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheet
        }
    }

    // MARK: - Top bar / header

    private var topBar: some View {
        HStack {
            Button("← Mode") { onBack() }

            Button("Clear Both") {
                leftDocument.clear()
                rightDocument.clear()
                leftError = nil
                rightError = nil
            }
            .disabled(leftDocument.fixtures.isEmpty && rightDocument.fixtures.isEmpty)

            Spacer()
        }
        .padding(10)
    }

    private var fileHeaderBar: some View {
        HStack(alignment: .top, spacing: 16) {
            fileHeaderColumn(
                label: "A",
                fileName: leftDocument.fileName,
                showColumns: $showFileAColumns,
                error: leftError,
                isTargeted: $isLeftTargeted,
                side: .left
            ) {
                exportSide = .left
                showExportSheet = true
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                Text("Match File A → B by…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Match by", selection: $matchMode) {
                    ForEach(MatchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            .frame(width: 220)
            .padding(.vertical, 12)

            fileHeaderColumn(
                label: "B",
                fileName: rightDocument.fileName,
                showColumns: $showFileBColumns,
                error: rightError,
                isTargeted: $isRightTargeted,
                side: .right
            ) {
                exportSide = .right
                showExportSheet = true
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private func fileHeaderColumn(
        label: String,
        fileName: String,
        showColumns: Binding<Bool>,
        error: String?,
        isTargeted: Binding<Bool>,
        side: DropSide,
        onExport: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Text(fileName.isEmpty ? "\(label): Drag .mvr file here" : "\(label): \(fileName)")
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Toggle("Show", isOn: showColumns)
                Button("Export Processed MVR \(label)", action: onExport)
                    .disabled(fileName.isEmpty)
                Button("Clear") {
                    clearFile(side)
                }
                .disabled(fileName.isEmpty)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(isTargeted.wrappedValue ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            handleDrop(providers: providers, side: side)
        }
    }

    private func clearFile(_ side: DropSide) {
        switch side {
        case .left:
            leftDocument.clear()
            leftError = nil
        case .right:
            rightDocument.clear()
            rightError = nil
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("A: \(leftDocument.fixtures.count) fixtures")
                .foregroundStyle(.secondary)
            Text("B: \(rightDocument.fixtures.count) fixtures")
                .foregroundStyle(.secondary)

            Spacer()

            Button("Copy Attributes…") {
                showCopyAttributesSheet = true
            }
            .disabled(matchedCount == 0)

            Button("Remove All Non-Patched Fixtures…") {
                showRemoveUnpatchedConfirm = true
            }
            .disabled(leftDocument.fixtures.isEmpty && rightDocument.fixtures.isEmpty)
            .confirmationDialog(
                "What counts as a non-patched fixture?",
                isPresented: $showRemoveUnpatchedConfirm,
                titleVisibility: .visible
            ) {
                Button("No DMX Patch — \(unpatchedCount(.noDMXPatch)) fixture(s)", role: .destructive) {
                    leftDocument.removeFixtures(matching: .noDMXPatch)
                    rightDocument.removeFixtures(matching: .noDMXPatch)
                }
                Button("No Fixture ID — \(unpatchedCount(.noFixtureID)) fixture(s)", role: .destructive) {
                    leftDocument.removeFixtures(matching: .noFixtureID)
                    rightDocument.removeFixtures(matching: .noFixtureID)
                }
                Button("Both — \(unpatchedCount(.both)) fixture(s)", role: .destructive) {
                    leftDocument.removeFixtures(matching: .both)
                    rightDocument.removeFixtures(matching: .both)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("No DMX Patch means Universe 1, Address 0. No Fixture ID means Fixture ID 0. Applies to both File A and File B.")
            }
        }
        .padding(10)
    }

    /// File A / File B with an arrow between them that flips on tap to
    /// reverse the copy direction — avoids the old two-button picker
    /// overflowing with long, similar-looking filenames.
    private var directionSelector: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text("A")
                    .font(.headline)
                Text(leftDocument.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    copyDirection = (copyDirection == .aToB) ? .bToA : .aToB
                }
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 22))
                    .rotationEffect(.degrees(copyDirection == .aToB ? 0 : 180))
            }
            .buttonStyle(.plain)
            .help("Click to reverse the copy direction")

            VStack(spacing: 2) {
                Text("B")
                    .font(.headline)
                Text(rightDocument.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var idFieldToggleLabel: String {
        switch matchMode {
        case .fixtureID: return "UUID"
        case .uuid: return "Fixture ID"
        }
    }

    private var anyCopyToggleOn: Bool {
        copyID || copyName || copyPatch || copyLayer || copyClass || copy3D || copyGDTF
    }

    private var copyAttributesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy Attributes")
                .font(.headline)

            directionSelector

            Text("Choose which fields to copy for the \(matchedCount) matched fixtures:")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(idFieldToggleLabel, isOn: $copyID)
                Toggle("Name", isOn: $copyName)
                Toggle("Patch (Universe / Address)", isOn: $copyPatch)
                Toggle("Layer", isOn: $copyLayer)
                Toggle("Class", isOn: $copyClass)
                Toggle("3D Position", isOn: $copy3D)
                Toggle("GDTF File", isOn: $copyGDTF)
            }

            HStack {
                Button("Select All") { setAllCopyToggles(true) }
                Button("Select All But DMX Patch") { setAllCopyTogglesExceptPatch() }
                Button("Select None") { setAllCopyToggles(false) }
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { showCopyAttributesSheet = false }
                Button("Copy") {
                    performAttributeCopy()
                    showCopyAttributesSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!anyCopyToggleOn)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func setAllCopyToggles(_ value: Bool) {
        copyID = value
        copyName = value
        copyPatch = value
        copyLayer = value
        copyClass = value
        copy3D = value
        copyGDTF = value
    }

    private func setAllCopyTogglesExceptPatch() {
        setAllCopyToggles(true)
        copyPatch = false
    }

    private func performAttributeCopy() {
        let (source, destination) = copyDirection == .aToB ? (leftDocument, rightDocument) : (rightDocument, leftDocument)

        for row in comparisonRows where row.status == .matched {
            guard let left = row.leftFixture, let right = row.rightFixture else { continue }
            let (sourceFixture, destinationFixtureID) = copyDirection == .aToB ? (left, right.id) : (right, left.id)

            if copyID {
                switch matchMode {
                case .fixtureID:
                    destination.setUUID(sourceFixture.currentUUID, forFixtureAtID: destinationFixtureID)
                case .uuid:
                    if let fixtureID = sourceFixture.currentFixtureID {
                        destination.setFixtureID(fixtureID, forFixtureAtID: destinationFixtureID)
                    }
                }
            }
            if copyName {
                destination.setName(sourceFixture.name, forFixtureAtID: destinationFixtureID)
            }
            if copyPatch, let address = sourceFixture.currentAddress {
                destination.setAddress(address, forFixtureAtID: destinationFixtureID)
            }
            if copyLayer {
                destination.setLayer(name: sourceFixture.layerName, uuid: sourceFixture.layerUUID, forFixtureAtID: destinationFixtureID)
            }
            if copyClass {
                destination.setClassing(sourceFixture.classing, forFixtureAtID: destinationFixtureID)
            }
            if copy3D {
                destination.setMatrix(sourceFixture.matrixText, forFixtureAtID: destinationFixtureID)
            }
            if copyGDTF {
                destination.copyGDTF(from: source, sourceFixtureID: sourceFixture.id, toFixtureAtID: destinationFixtureID)
            }
        }
    }

    // MARK: - Comparison table

    private var visibleComparisonRows: [MVRComparisonRow] {
        comparisonRows.filter { row in
            if !showFileAColumns && row.status == .leftOnly { return false }
            if !showFileBColumns && row.status == .rightOnly { return false }
            return true
        }
    }

    /// A row matches if either side's fixture matches — hiding a whole
    /// matched pair just because one side's name differs would be
    /// surprising in a comparison table.
    private var filteredComparisonRows: [MVRComparisonRow] {
        guard !filterText.isEmpty else { return visibleComparisonRows }
        return visibleComparisonRows.filter { row in
            (row.leftFixture?.matchesFilter(filterText, field: filterField) ?? false)
                || (row.rightFixture?.matchesFilter(filterText, field: filterField) ?? false)
        }
    }

    private var sortedComparisonRows: [MVRComparisonRow] {
        filteredComparisonRows.sorted(using: sortOrder)
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

            Text("\(sortedComparisonRows.count) of \(comparisonRows.count)")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var comparisonTable: some View {
        Table(sortedComparisonRows, sortOrder: $sortOrder) {
            TableColumn("Status") { row in
                cell(row: row) {
                    HStack(spacing: 6) {
                        statusLabel(row.status)
                        DeleteRowButton {
                            if let left = row.leftFixture {
                                leftDocument.deleteFixture(withID: left.id)
                            }
                            if let right = row.rightFixture {
                                rightDocument.deleteFixture(withID: right.id)
                            }
                        }
                    }
                }
            }
            if showFileAColumns {
                TableColumn("A: Name", sortUsing: KeyPathComparator(\.leftNameSort)) { row in
                    cell(row: row) {
                        Text(row.leftFixture?.name ?? "-")
                            .foregroundStyle(matches(row, \.name) ? .green : .primary)
                    }
                }
                TableColumn("A: Fixture ID", sortUsing: KeyPathComparator(\.leftFixtureIDSort)) { row in
                    cell(row: row) {
                        Text(row.leftFixture?.currentFixtureID.map(String.init) ?? "-")
                            .foregroundStyle(matches(row, \.currentFixtureID) ? .green : .primary)
                    }
                }
                TableColumn("A: UUID", sortUsing: KeyPathComparator(\.leftUUIDSort)) { row in
                    cell(row: row) {
                        if let uuid = row.leftFixture?.currentUUID {
                            UUIDCell(uuid: uuid, color: matches(row, \.currentUUID) ? .green : .gray)
                        } else {
                            Text("-")
                        }
                    }
                }
                TableColumn("A: Layer", sortUsing: KeyPathComparator(\.leftLayerSort)) { row in
                    cell(row: row) {
                        Text(row.leftFixture.map { $0.layerName.isEmpty ? "-" : $0.layerName } ?? "-")
                            .foregroundStyle(matches(row, \.layerName) ? .green : .primary)
                    }
                }
                TableColumn("A: Address", sortUsing: KeyPathComparator(\.leftAddressSort)) { row in
                    cell(row: row, isBoundary: true) {
                        Text(addressText(for: row.leftFixture))
                            .foregroundStyle(matches(row, \.currentAddress) ? .green : .primary)
                    }
                }
            }
            if showFileBColumns {
                TableColumn("B: Name", sortUsing: KeyPathComparator(\.rightNameSort)) { row in
                    cell(row: row) {
                        Text(row.rightFixture?.name ?? "-")
                            .foregroundStyle(matches(row, \.name) ? .green : .primary)
                    }
                }
                TableColumn("B: Fixture ID", sortUsing: KeyPathComparator(\.rightFixtureIDSort)) { row in
                    cell(row: row) {
                        Text(row.rightFixture?.currentFixtureID.map(String.init) ?? "-")
                            .foregroundStyle(matches(row, \.currentFixtureID) ? .green : .primary)
                    }
                }
                TableColumn("B: UUID", sortUsing: KeyPathComparator(\.rightUUIDSort)) { row in
                    cell(row: row) {
                        if let uuid = row.rightFixture?.currentUUID {
                            UUIDCell(uuid: uuid, color: matches(row, \.currentUUID) ? .green : .gray)
                        } else {
                            Text("-")
                        }
                    }
                }
                TableColumn("B: Layer", sortUsing: KeyPathComparator(\.rightLayerSort)) { row in
                    cell(row: row) {
                        Text(row.rightFixture.map { $0.layerName.isEmpty ? "-" : $0.layerName } ?? "-")
                            .foregroundStyle(matches(row, \.layerName) ? .green : .primary)
                    }
                }
                TableColumn("B: Address", sortUsing: KeyPathComparator(\.rightAddressSort)) { row in
                    cell(row: row) {
                        Text(addressText(for: row.rightFixture))
                            .foregroundStyle(matches(row, \.currentAddress) ? .green : .primary)
                    }
                }
            }
        }
    }

    /// True when the row is a match and both sides have equal values for
    /// the given field — used to color individual matching fields green.
    private func matches<T: Equatable>(_ row: MVRComparisonRow, _ keyPath: KeyPath<MVRFixture, T>) -> Bool {
        guard row.status == .matched, let left = row.leftFixture, let right = row.rightFixture else { return false }
        return left[keyPath: keyPath] == right[keyPath: keyPath]
    }

    /// Wraps a column's content so it fills the cell width and picks up the
    /// green "matched" highlight, keeping that logic in one place.
    private func cell<Content: View>(row: MVRComparisonRow, isBoundary: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(row.status == .matched ? Color.green.opacity(0.08) : Color.clear)
            .overlay(alignment: .trailing) {
                if isBoundary {
                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 2)
                }
            }
    }

    private func addressText(for fixture: MVRFixture?) -> String {
        guard let fixture else { return "-" }
        return "\(fixture.universe) / \(fixture.channel)"
    }

    private func statusLabel(_ status: ComparisonStatus) -> some View {
        switch status {
        case .matched:
            return Text("Matched").foregroundStyle(.green)
        case .leftOnly:
            return Text("Only in A").foregroundStyle(.orange)
        case .rightOnly:
            return Text("Only in B").foregroundStyle(.orange)
        }
    }

    // MARK: - Loading

    private func handleDrop(providers: [NSItemProvider], side: DropSide) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard
                let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil),
                url.pathExtension.lowercased() == "mvr"
            else {
                DispatchQueue.main.async {
                    switch side {
                    case .left: self.leftError = "Please drop a valid .mvr file."
                    case .right: self.rightError = "Please drop a valid .mvr file."
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self.pendingDrop = (side, url)

                // Only ask when the file genuinely doesn't say which field
                // is real — same detection Single Edit uses on import.
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
        guard let pending = pendingDrop else { return }
        pendingDrop = nil

        let targetDocument = pending.side == .left ? leftDocument : rightDocument
        do {
            try targetDocument.load(from: pending.url, idFieldName: idFieldName)
            switch pending.side {
            case .left: leftError = nil
            case .right: rightError = nil
            }
        } catch {
            let message = "Failed to parse MVR file: \(error.localizedDescription)"
            switch pending.side {
            case .left: leftError = message
            case .right: rightError = message
            }
        }
    }

    // MARK: - Export

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(exportSide == .left ? "Export File A (\(leftDocument.fileName))" : "Export File B (\(rightDocument.fileName))")
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
        .frame(width: 440)
    }

    private func presentSavePanelAndExport() {
        guard let side = exportSide else { return }
        let document = side == .left ? leftDocument : rightDocument

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
                    switch side {
                    case .left: self.leftError = "Export failed: \(error.localizedDescription)"
                    case .right: self.rightError = "Export failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

#Preview {
    CompareView(onBack: {})
}
