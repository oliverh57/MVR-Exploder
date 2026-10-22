import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The fixture table for the open file, every field editable.
///
/// Works on the app's one document, so what's changed here is already in
/// the 3D view, the ID map and every other tool the moment you go back —
/// and leaving never asks, because nothing is lost by it. Opening a file
/// and writing one out are on the tools page.
struct SingleEditView: View {
    @ObservedObject var document: MVRDocument
    /// Fixtures to pick out on arrival, from a click in the 3D view or the
    /// ID map on the tools page.
    var reveal: Set<String> = []
    let onBack: () -> Void

    @State private var showOffsetSheet = false
    @State private var offsetInput = ""

    @State private var showUniverseOffsetSheet = false
    @State private var universeOffsetInput = ""

    @State private var showRegenerateUUIDConfirm = false
    @State private var showRemoveUnpatchedConfirm = false
    // Patch Check is switched off until its findings can be trusted.
    // @State private var showPatchCheck = false
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
            topBar
            Divider()
            filterBar
            Divider()
            fixturesTable
            Divider()
            bottomBar
        }
        .onAppear {
            if !reveal.isEmpty { revealFixtures(ids: reveal) }
        }
        .sheet(isPresented: $showOffsetSheet) {
            offsetSheet
        }
        .sheet(isPresented: $showUniverseOffsetSheet) {
            universeOffsetSheet
        }
        // Patch Check is switched off until its findings can be trusted.
        // .sheet(isPresented: $showPatchCheck) {
        //     PatchCheckView(
        //         document: document,
        //         onClose: { showPatchCheck = false },
        //         onSelectFixtures: { revealFixtures(ids: $0) })
        // }
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
    static func scrollTableToRow(_ row: Int, rowCount: Int) {
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

    // The 3D view, the ID map, the patch PDF and exporting are on the
    // tools page; Patch Check is switched off until its findings can be
    // trusted.
    // Button("Patch Check…") { showPatchCheck = true }
    private var topBar: some View {
        ToolHeader("Single Edit", onBack: onBack)
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
            validate: { field.validate($0) },
            onCommit: { apply($0, to: field, of: fixture) },
            onReset: { document.resetField(field, forFixtureAtID: fixture.id) },
            content: content)
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
                Text("Every fixture gets a new UUID. Reset Changes undoes it.")
            }

            Button("Remove All Non-Patched Fixtures…") {
                showRemoveUnpatchedConfirm = true
            }
            .disabled(document.fixtures.isEmpty)
            .confirmationDialog(
                "Remove fixtures with…",
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
                Text("No patch means Universe 1, Address 0. No ID means Fixture ID 0.")
            }
        }
        .padding(10)
    }

    private var offsetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Offset Fixture IDs")
                .font(.headline)
            Text("Added to every Fixture ID. Use a negative number to go down.")
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
            Text("Moves every fixture by this many universes. Use a negative number to go down.")
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
}

#Preview {
    SingleEditView(document: MVRDocument(), onBack: {})
}
