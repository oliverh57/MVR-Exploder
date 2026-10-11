import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The open file (A) beside a second MVR (B), matched fixture by fixture.
///
/// A is the app's own document — every change made here, copied
/// attributes and merged fixtures alike, is in it when you go back. B is
/// loaded here for the comparison and is never written anywhere: it is a
/// source to take from, so copying runs one way, B into A.
struct CompareView: View {
    @ObservedObject var leftDocument: MVRDocument
    let onBack: () -> Void

    @StateObject private var rightDocument = MVRDocument()

    @State private var rightError: String?
    @State private var isRightTargeted = false

    // Drag-and-drop → ask which field holds the fixture ID before loading.
    @State private var pendingFile: MVRSceneFile?
    @State private var showFieldChoiceDialog = false
    @State private var isOpeningB = false
    /// What the last merge did, for the bar along the bottom.
    @State private var mergeMessage: String?
    /// Rows changed from B while it's been open, by A's fixture — without
    /// these a fixture just added from B reads "Same", like any other.
    @State private var addedIDs: Set<String> = []
    @State private var updatedIDs: Set<String> = []

    @State private var matchMode: MatchMode = .uuid
    @State private var showFileAColumns = true
    @State private var showFileBColumns = true
    @State private var sortOrder: [KeyPathComparator<MVRComparisonRow>] = []
    @State private var selectedRowIDs: Set<String> = []
    @State private var filterField: FixtureFilterField = .name
    @State private var filterText = ""

    @State private var showCopyAttributesSheet = false
    /// The rows the copy applies to — the selection it was opened from —
    /// or nil for every matched row.
    @State private var copyScope: Set<String>?
    @State private var copyID = true
    @State private var copyName = false
    @State private var copyPatch = false
    @State private var copyLayer = false
    @State private var copyClass = false
    @State private var copy3D = false
    @State private var copyGDTF = false

    private var comparisonRows: [MVRComparisonRow] {
        MVRComparator.compare(left: leftDocument.fixtures, right: rightDocument.fixtures, matchMode: matchMode)
    }

    private var matchedCount: Int {
        comparisonRows.filter { $0.status == .matched }.count
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
            "Which field holds the fixture IDs?",
            isPresented: $showFieldChoiceDialog,
            titleVisibility: .visible
        ) {
            Button("FixtureID") { loadPendingDrop(idFieldName: "FixtureID") }
            Button("UnitNumber (Channel)") { loadPendingDrop(idFieldName: "UnitNumber") }
            Button("Cancel", role: .cancel) { pendingFile = nil }
        } message: {
            Text("This file has IDs in both. Most consoles use FixtureID; some use UnitNumber (Channel).")
        }
        .sheet(isPresented: $showCopyAttributesSheet) {
            copyAttributesSheet
        }
        // An undo may have taken a copy back out, and there's no telling
        // which: better no mark than one that's wrong. Added rows need no
        // help — undone, the fixture leaves A and the row is B's again.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in
            updatedIDs = []
        }
    }

    // MARK: - Top bar / header

    private var topBar: some View {
        ToolHeader("Compare & Merge", onBack: onBack)
    }

    /// The two files either side of how they're matched, laid out as the
    /// table is beneath them: A on the left, B on the right.
    private var fileHeaderBar: some View {
        HStack(spacing: 16) {
            fileASide
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text("Match by")
                    .foregroundStyle(.secondary)
                Picker("Match by", selection: $matchMode) {
                    ForEach(MatchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            fileBSide
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The open file, which is only ever changed by opening another from
    /// the tools page.
    private var fileASide: some View {
        HStack(spacing: 10) {
            fileBadge("A", color: .secondary)
            fileTitle(leftDocument.fileName, note: "Your open file.")
            Spacer(minLength: 0)
            showToggle($showFileAColumns, file: "A")
        }
        .padding(4)
    }

    private var fileBSide: some View {
        HStack(spacing: 10) {
            fileBadge("B", color: .blue)
            if isOpeningB {
                ProgressView()
                    .controlSize(.small)
                Text("Opening…")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if rightDocument.fileName.isEmpty {
                chooseBZone
            } else {
                fileTitle(rightDocument.fileName, note: rightError ?? "For comparing. Not saved.",
                          isError: rightError != nil)
                Spacer(minLength: 0)
                showToggle($showFileBColumns, file: "B")
                Button("Replace…") { chooseFileB() }
                Button("Clear", action: clearB)
            }
        }
        .padding(4)
        .background(isRightTargeted ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .onDrop(of: [.fileURL], isTargeted: $isRightTargeted) { handleDrop(providers: $0) }
    }

    /// No B yet: the place to put one, for a click or a drop.
    private var chooseBZone: some View {
        Button(action: chooseFileB) {
            HStack(spacing: 6) {
                Image(systemName: rightError == nil ? "plus.circle" : "exclamationmark.triangle")
                Text(rightError ?? "Choose an MVR to compare, or drop one here")
                    .lineLimit(1)
            }
            .foregroundStyle(rightError == nil ? Color.accentColor : .red)
            .frame(maxWidth: .infinity, minHeight: 34)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rightError ?? "Choose the MVR to compare your file with.")
    }

    /// The letter the table's columns go by, in the colour of the file's
    /// "only" status.
    private func fileBadge(_ letter: String, color: Color) -> some View {
        Text(letter)
            .font(.headline)
            .foregroundStyle(color)
            .frame(width: 26, height: 26)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private func fileTitle(_ name: String, note: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(note)
                .font(.caption)
                .foregroundStyle(isError ? Color.red : .secondary)
                .lineLimit(1)
        }
        .help(name)
    }

    /// Whether the file's columns, and the fixtures only it has, are in
    /// the table.
    private func showToggle(_ isShown: Binding<Bool>, file: String) -> some View {
        Button {
            isShown.wrappedValue.toggle()
        } label: {
            Image(systemName: isShown.wrappedValue ? "eye" : "eye.slash")
                .frame(width: 20)
        }
        .buttonStyle(.borderless)
        .help(isShown.wrappedValue ? "Hide \(file) in the table." : "Show \(file) in the table.")
    }

    private func clearB() {
        rightDocument.clear()
        rightError = nil
        mergeMessage = nil
        addedIDs = []
        updatedIDs = []
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("A: \(leftDocument.fixtures.count) fixtures")
                .foregroundStyle(.secondary)
            Text("B: \(rightDocument.fixtures.count) fixtures")
                .foregroundStyle(.secondary)

            if let mergeMessage {
                Text(mergeMessage)
                    .foregroundStyle(.green)
            } else if !rightDocument.fixtures.isEmpty {
                Text("Right-click rows to copy fixtures into A.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Copy Attributes from B…") {
                copyScope = nil
                showCopyAttributesSheet = true
            }
            .disabled(matchedCount == 0)
        }
        .padding(10)
    }

    /// B into A, said once: B is never saved, so there is no other way
    /// round a copy could usefully go. A on the left and B on the right, as
    /// they are on the screen behind it, with the arrow coming back across.
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

            Image(systemName: "arrow.left.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)

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

    /// The matched rows the copy will touch.
    private var copyRows: [MVRComparisonRow] {
        comparisonRows.filter { row in
            row.status == .matched && (copyScope?.contains(row.id) ?? true)
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

            Text("Copy from B to \(copyRows.count) matched fixture\(copyRows.count == 1 ? "" : "s"):")
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
        let (source, destination) = (rightDocument, leftDocument)
        let rows = copyRows

        for row in rows {
            guard let left = row.leftFixture, let right = row.rightFixture else { continue }
            let (sourceFixture, destinationFixtureID) = (right, left.id)

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

        updatedIDs.formUnion(rows.compactMap { $0.leftFixture?.id })
        mergeMessage = "Copied attributes from B to \(rows.count) fixture\(rows.count == 1 ? "" : "s") in A."
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
        guard sortOrder.isEmpty else { return filteredComparisonRows.sorted(using: sortOrder) }
        return keepingAddedRowsInPlace(filteredComparisonRows)
    }

    /// A fixture added from B is A's now, so the comparison lists it with
    /// A's — at the end of them, a long way from the B row it was added
    /// from. Unsorted, it stays where it was: among B's, in B's order.
    private func keepingAddedRowsInPlace(_ rows: [MVRComparisonRow]) -> [MVRComparisonRow] {
        guard !addedIDs.isEmpty else { return rows }
        let orderInB = Dictionary(
            rightDocument.fixtures.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first })
        func isFromB(_ row: MVRComparisonRow) -> Bool {
            row.status == .rightOnly || addedIDs.contains(row.id)
        }
        func position(_ row: MVRComparisonRow) -> Int {
            row.rightFixture.flatMap { orderInB[$0.id] } ?? .max
        }
        return rows.filter { !isFromB($0) }
            + rows.filter(isFromB).sorted { position($0) < position($1) }
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
        Table(sortedComparisonRows, selection: $selectedRowIDs, sortOrder: $sortOrder) {
            TableColumn("") { row in
                DeleteRowButton {
                    if let left = row.leftFixture {
                        leftDocument.deleteFixture(withID: left.id)
                    }
                    if let right = row.rightFixture {
                        rightDocument.deleteFixture(withID: right.id)
                    }
                }
            }
            .width(28)

            if showFileAColumns {
                TableColumn("A: Name", sortUsing: KeyPathComparator(\.leftNameSort)) { row in
                    if row.status == .rightOnly {
                        addToAButton(row)
                    } else {
                        value(row, row.leftFixture, \.name) { $0.name }
                    }
                }
                .width(min: 70, ideal: 100)
                TableColumn("A: Fixture ID", sortUsing: KeyPathComparator(\.leftFixtureIDSort)) { row in
                    value(row, row.leftFixture, \.currentFixtureID) { $0.currentFixtureID.map(String.init) ?? "" }
                        .monospacedDigit()
                }
                .width(min: 44, ideal: 48, max: 90)
                TableColumn("A: UUID", sortUsing: KeyPathComparator(\.leftUUIDSort)) { row in
                    if let fixture = row.leftFixture {
                        uuidCell(row, fixture)
                    }
                }
                .width(min: 72, ideal: 76, max: 100)
                TableColumn("A: Layer", sortUsing: KeyPathComparator(\.leftLayerSort)) { row in
                    value(row, row.leftFixture, \.layerName) { $0.layerName }
                }
                .width(min: 50, ideal: 64)
                TableColumn("A: Address", sortUsing: KeyPathComparator(\.leftAddressSort)) { row in
                    value(row, row.leftFixture, \.currentAddress, addressText)
                        .monospacedDigit()
                }
                .width(min: 56, ideal: 56, max: 100)
            }

            // Between the two files, so it reads as the verdict on the
            // pair either side of it.
            TableColumn("Status") { row in
                statusBadge(row)
                    .frame(maxWidth: .infinity)
            }
            .width(min: 72, ideal: 76, max: 96)

            if showFileBColumns {
                TableColumn("B: Name", sortUsing: KeyPathComparator(\.rightNameSort)) { row in
                    value(row, row.rightFixture, \.name) { $0.name }
                }
                .width(min: 70, ideal: 100)
                TableColumn("B: Fixture ID", sortUsing: KeyPathComparator(\.rightFixtureIDSort)) { row in
                    value(row, row.rightFixture, \.currentFixtureID) { $0.currentFixtureID.map(String.init) ?? "" }
                        .monospacedDigit()
                }
                .width(min: 44, ideal: 48, max: 90)
                TableColumn("B: UUID", sortUsing: KeyPathComparator(\.rightUUIDSort)) { row in
                    if let fixture = row.rightFixture {
                        uuidCell(row, fixture)
                    }
                }
                .width(min: 72, ideal: 76, max: 100)
                TableColumn("B: Layer", sortUsing: KeyPathComparator(\.rightLayerSort)) { row in
                    value(row, row.rightFixture, \.layerName) { $0.layerName }
                }
                .width(min: 50, ideal: 64)
                TableColumn("B: Address", sortUsing: KeyPathComparator(\.rightAddressSort)) { row in
                    value(row, row.rightFixture, \.currentAddress, addressText)
                        .monospacedDigit()
                }
                .width(min: 56, ideal: 56, max: 100)
            }
        }
        // Right-clicking inside a selection acts on all of it; right-clicking
        // an unselected row acts on that row alone. Deletes both sides of a
        // row, as the row's own delete button does.
        .contextMenu(forSelectionType: String.self) { ids in
            let rows = comparisonRows.filter { ids.contains($0.id) }
            let onlyInB = rows.filter { $0.status == .rightOnly }
            let matched = rows.filter { $0.status == .matched }
            let added = rows.filter { addedIDs.contains($0.id) }

            // Only in B: the fixture itself comes across, whole.
            if !onlyInB.isEmpty {
                Button(onlyInB.count == 1
                       ? "Add This Fixture to A"
                       : "Add \(onlyInB.count) Fixtures to A") {
                    addToA(onlyInB)
                }
            }
            // In both: the usual copy, onto the fixture A already has.
            if !matched.isEmpty {
                Button(matched.count == 1
                       ? "Copy Attributes from B…"
                       : "Copy Attributes from B for \(matched.count)…") {
                    copyScope = Set(matched.map(\.id))
                    showCopyAttributesSheet = true
                }
            }
            if !added.isEmpty {
                Button(added.count == 1
                       ? "Undo Add to A"
                       : "Undo Adding \(added.count) Fixtures to A") {
                    undoAdd(Set(added.map(\.id)))
                }
            }
            if !onlyInB.isEmpty || !matched.isEmpty {
                Divider()
            }
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Delete Row" : "Delete \(ids.count) Rows", role: .destructive) {
                    deleteRows(withIDs: ids)
                }
            }
        }
    }

    /// Brings fixtures that are only in B into A.
    ///
    /// Once they're in, the rows they came from match — on UUID by
    /// definition, and on Fixture ID because the ID comes with them — so
    /// the table itself shows the merge has happened.
    private func addToA(_ rows: [MVRComparisonRow]) {
        let incoming = rows.compactMap(\.rightFixture)
        // Counted before the import: these are the ones it will have to
        // give a new UUID, because A already uses theirs.
        let inUse = Set(leftDocument.fixtures.map { $0.currentUUID.lowercased() })
        let renamed = incoming.filter { inUse.contains($0.currentUUID.lowercased()) }.count
        let added = leftDocument.importFixtures(withIDs: incoming.map(\.id), from: rightDocument)

        var message = "Added \(added.count) fixture\(added.count == 1 ? "" : "s") to A."
        if renamed > 0 {
            message += " \(renamed) got new UUIDs to avoid clashes."
        }
        mergeMessage = message
        addedIDs.formUnion(added)
        // Picked out where they now sit, A's side filled in.
        selectedRowIDs = Set(added)
    }

    private func deleteRows(withIDs ids: Set<String>) {
        let rows = comparisonRows.filter { ids.contains($0.id) }
        leftDocument.deleteFixtures(withIDs: Set(rows.compactMap { $0.leftFixture?.id }))
        rightDocument.deleteFixtures(withIDs: Set(rows.compactMap { $0.rightFixture?.id }))
        selectedRowIDs.subtract(ids)
    }

    /// True when both sides have a fixture and they disagree on the field —
    /// what the comparison is for, so it's what gets the colour.
    private func differs<T: Equatable>(_ row: MVRComparisonRow, _ keyPath: KeyPath<MVRFixture, T>) -> Bool {
        guard let left = row.leftFixture, let right = row.rightFixture else { return false }
        return left[keyPath: keyPath] != right[keyPath: keyPath]
    }

    /// Any of the columns shown disagreeing.
    private func hasDifferences(_ row: MVRComparisonRow) -> Bool {
        differs(row, \.name) || differs(row, \.currentFixtureID) || differs(row, \.currentUUID)
            || differs(row, \.layerName) || differs(row, \.currentAddress)
    }

    /// One side's value. Blank where that side has no fixture — the status
    /// says so once, rather than a dash in every column — and orange where
    /// a matched pair disagrees.
    @ViewBuilder
    private func value<T: Equatable>(
        _ row: MVRComparisonRow, _ fixture: MVRFixture?, _ keyPath: KeyPath<MVRFixture, T>,
        _ text: (MVRFixture) -> String
    ) -> some View {
        if let fixture {
            let shown = text(fixture)
            Text(shown.isEmpty ? "—" : shown)
                .foregroundStyle(differs(row, keyPath) ? Color.orange
                                 : shown.isEmpty ? Color.secondary : Color.primary)
        }
    }

    /// The first block of the UUID: enough to tell two apart at a glance,
    /// with the whole thing a hover away.
    private func uuidCell(_ row: MVRComparisonRow, _ fixture: MVRFixture) -> some View {
        UUIDCell(uuid: fixture.currentUUID,
                 color: differs(row, \.currentUUID) ? .orange : .secondary,
                 label: String(fixture.currentUUID.prefix(8)))
            .font(.body.monospaced())
    }

    private func addressText(for fixture: MVRFixture) -> String {
        guard fixture.currentAddress != nil else { return "" }
        return "\(fixture.universe) / \(fixture.channel)"
    }

    /// In the empty A side of a fixture only B has — where it will land.
    /// Inside a selection it adds every B-only row selected, as
    /// right-clicking there does; outside one, just its own row.
    private func addToAButton(_ row: MVRComparisonRow) -> some View {
        let isBulk = selectedRowIDs.contains(row.id)
        let count = isBulk ? selectedOnlyInBCount : 1
        return Button {
            addToA(isBulk
                   ? comparisonRows.filter { $0.status == .rightOnly && selectedRowIDs.contains($0.id) }
                   : [row])
        } label: {
            // The words while they fit, the arrow alone once they don't:
            // wrapped, they doubled the height of every B row.
            ViewThatFits(in: .horizontal) {
                Label(count > 1 ? "Add \(count) to A" : "Add to A", systemImage: "arrow.left.circle")
                Image(systemName: "arrow.left.circle")
            }
            .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .help(count > 1
              ? "Copy the \(count) selected fixtures from B into your file."
              : "Copy this fixture from B into your file.")
    }

    /// B-only rows go by B's fixture and every other row by A's, so the
    /// selected B fixtures are the selected B-only rows. Counted this way
    /// rather than through the comparison, which every row's button would
    /// otherwise be running again.
    private var selectedOnlyInBCount: Int {
        let inB = Set(rightDocument.fixtures.map(\.id))
        return selectedRowIDs.filter(inB.contains).count
    }

    @ViewBuilder
    private func statusBadge(_ row: MVRComparisonRow) -> some View {
        if row.status == .matched, addedIDs.contains(row.id) {
            // "Added" is also the way back out. Inside a selection, for
            // every added row selected, as Add to A is.
            let ids = selectedRowIDs.contains(row.id)
                ? selectedRowIDs.intersection(addedIDs)
                : [row.id]
            UndoAddPill(count: ids.count) { undoAdd(ids) }
        } else {
            let (label, color) = status(of: row)
            StatusPill(label: label, color: color)
        }
    }

    private func status(of row: MVRComparisonRow) -> (String, Color) {
        switch row.status {
        case .matched where updatedIDs.contains(row.id): ("Updated", .purple)
        case .matched: hasDifferences(row) ? ("Differs", .orange) : ("Same", .green)
        case .leftOnly: ("A only", .secondary)
        case .rightOnly: ("B only", .blue)
        }
    }

    /// Takes fixtures added from B back out of A. Their rows are B's
    /// again, in the same place, and stay picked out.
    private func undoAdd(_ ids: Set<String>) {
        let backInB = Set(comparisonRows.filter { ids.contains($0.id) }.compactMap { $0.rightFixture?.id })
        leftDocument.deleteFixtures(withIDs: ids)
        addedIDs.subtract(ids)
        mergeMessage = "Took \(ids.count) fixture\(ids.count == 1 ? "" : "s") back out of A."
        selectedRowIDs = backInB
    }

    // MARK: - Loading B

    private func chooseFileB() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mvr")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        begin(with: url)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard
                let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil),
                url.pathExtension.lowercased() == "mvr"
            else {
                DispatchQueue.main.async { self.rightError = "Please drop a valid .mvr file." }
                return
            }
            DispatchQueue.main.async { self.begin(with: url) }
        }
        return true
    }

    private func begin(with url: URL) {
        guard !isOpeningB else { return }
        isOpeningB = true
        Task {
            defer { isOpeningB = false }
            do {
                let file = try await MVRDocument.readInBackground(from: url)
                pendingFile = file
                // Only ask when the file genuinely doesn't say which field
                // is real — the same detection the load screen uses.
                switch file.idField {
                case .determined(let fieldName): loadPendingDrop(idFieldName: fieldName)
                case .ambiguous: showFieldChoiceDialog = true
                }
            } catch {
                rightError = "Couldn't read that MVR: \(error.localizedDescription)"
            }
        }
    }

    private func loadPendingDrop(idFieldName: String) {
        guard let file = pendingFile else { return }
        pendingFile = nil
        rightDocument.load(file, idFieldName: idFieldName)
        rightError = nil
        mergeMessage = nil
        addedIDs = []
        updatedIDs = []
    }
}

/// How a row's two sides compare, in a word.
private struct StatusPill: View {
    let label: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
            }
            Text(label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(minWidth: 60)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// "Added", turning into what a click on it does once the pointer is
/// there.
private struct UndoAddPill: View {
    let count: Int
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            StatusPill(
                label: isHovered ? (count > 1 ? "Undo \(count)" : "Undo") : "Added",
                color: isHovered ? .red : .purple,
                symbol: "arrow.uturn.backward")
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(count > 1
              ? "Take the \(count) selected fixtures back out of A."
              : "Take this fixture back out of A.")
    }
}

#Preview {
    CompareView(leftDocument: MVRDocument(), onBack: {})
}
