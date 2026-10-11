import SwiftUI

/// Every editable setting of a fixture, in one small form.
///
/// Opened by clicking a cell in the Fixture ID map or a fixture in the 3D
/// viewer, so a wrong ID or address can be fixed where it was spotted
/// rather than by going off to the table to find it. Writes through the
/// same document setters, and checks values by the same rules, as the
/// table.
///
/// Two ways in. `.each` edits fixtures one at a time — the two on a
/// clashing ID, with a switch between them. `.together` edits a selection
/// in one go: the fields that make sense for many fixtures at once, left
/// blank where they differ so that only what's typed is changed.
struct FixtureEditor: View {
    enum Scope {
        case each
        case together
    }

    @ObservedObject var document: MVRDocument
    let fixtureIDs: [String]
    var scope: Scope = .each
    let onClose: () -> Void

    @State private var current: String?
    @State private var name = ""
    @State private var fixtureID = ""
    @State private var universe = ""
    @State private var channel = ""
    @State private var mode = ""
    @State private var layerUUID = ""
    @State private var uuid = ""
    @State private var problem: String?
    @State private var isConfirmingDelete = false
    /// The modes the fixture type's GDTF lists, for the mode menu. Empty
    /// when the file has no GDTF for it, and the mode is typed instead.
    @State private var modes: [String] = []
    /// Set by "Generate New" in a bulk edit: every fixture gets its own
    /// fresh UUID on Apply.
    @State private var regeneratesUUIDs = false

    /// What the fields started as, so a bulk apply only touches what was
    /// changed.
    @State private var loaded: [String: String] = [:]

    private var isBulk: Bool { scope == .together && fixtureIDs.count > 1 }

    private var fixtures: [MVRFixture] {
        let wanted = Set(fixtureIDs)
        return document.fixtures.filter { wanted.contains($0.id) }
    }

    private var fixture: MVRFixture? {
        let id = current ?? fixtureIDs.first
        return document.fixtures.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isBulk {
                bulkHeader
                bulkForm
            } else if let fixture {
                header(fixture)
                if fixtureIDs.count > 1 {
                    Picker("", selection: Binding(
                        get: { current ?? fixtureIDs.first ?? "" },
                        set: { current = $0 })) {
                        ForEach(fixtureIDs, id: \.self) { id in
                            Text(document.fixtures.first { $0.id == id }?.name ?? id).tag(id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                form
            } else {
                Text("This fixture is no longer in the file.")
                    .foregroundStyle(.secondary)
                Button("Close", action: onClose)
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !fixtures.isEmpty {
                footer
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear(perform: load)
        .onChange(of: current) { _, _ in load() }
    }

    private var footer: some View {
        Group {
            if isConfirmingDelete {
                let count = isBulk ? fixtures.count : 1
                HStack {
                    Text("Delete \(count == 1 ? "this fixture" : "\(count) fixtures")?")
                        .font(.callout)
                    Spacer()
                    Button("Keep") { isConfirmingDelete = false }
                    Button("Delete", role: .destructive) { delete() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            } else {
                HStack {
                    Button(isBulk ? "Delete \(fixtures.count)…" : "Delete…", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .foregroundStyle(.red)
                    Spacer()
                    Button("Cancel", action: onClose)
                        .keyboardShortcut(.cancelAction)
                    Button("Apply") { isBulk ? applyToAll() : fixture.map(apply(to:)) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - One fixture

    private func header(_ fixture: MVRFixture) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fixture.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(GDTFSpecName.readable(fixture.gdtfSpec))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            closeButton
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
    }

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            row("Name") { TextField("", text: $name) }
            row("Fixture ID") { TextField("", text: $fixtureID).frame(width: 90) }
            row("Patch") {
                HStack(spacing: 6) {
                    TextField("", text: $universe).frame(width: 52)
                    Text(".").foregroundStyle(.secondary)
                    TextField("", text: $channel).frame(width: 52)
                    Text("universe . channel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            row("Mode") { modeField(allowsMixed: false) }
            row("Layer") { layerPicker(allowsMixed: false) }
            row("UUID") {
                let isNew = uuid != fixture?.currentUUID
                Button(isNew ? "New UUID on Apply" : "Generate New") {
                    uuid = UUID().uuidString.lowercased()
                }
                .disabled(isNew)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    // MARK: - Several at once

    private var bulkHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(fixtures.count) fixtures")
                    .font(.headline)
                Text(typeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            closeButton
        }
    }

    private var typeSummary: String {
        let types = Set(fixtures.map { GDTFSpecName.readable($0.gdtfSpec) }).sorted()
        return types.count <= 2 ? types.joined(separator: ", ") : "\(types.count) types"
    }

    private var bulkForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            row("Name") { TextField(placeholder(for: "name"), text: $name) }
            row("Number from") {
                HStack(spacing: 6) {
                    TextField("keep", text: $fixtureID).frame(width: 90)
                    Text("in ID order")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            row("Universe") {
                HStack(spacing: 6) {
                    TextField(placeholder(for: "universe"), text: $universe).frame(width: 90)
                    Text("channels kept")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            row("Mode") {
                if Set(fixtures.map(\.gdtfSpec)).count == 1 {
                    modeField(allowsMixed: true)
                } else {
                    Text("Mixed types")
                        .foregroundStyle(.secondary)
                }
            }
            row("Layer") { layerPicker(allowsMixed: true) }
            row("UUIDs") {
                Button(regeneratesUUIDs ? "New UUIDs on Apply" : "Generate New") {
                    regeneratesUUIDs = true
                }
                .disabled(regeneratesUUIDs)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func placeholder(for key: String) -> String {
        loaded[key] == nil ? "mixed" : ""
    }

    // MARK: - Shared pieces

    /// A menu of the GDTF's modes, or a text field when there's no GDTF to
    /// read them from.
    @ViewBuilder
    private func modeField(allowsMixed: Bool) -> some View {
        if modes.isEmpty {
            TextField(allowsMixed ? placeholder(for: "mode") : "", text: $mode)
        } else {
            Picker("", selection: $mode) {
                if allowsMixed && loaded["mode"] == nil {
                    Text("mixed").tag("")
                }
                ForEach(modes, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        }
    }

    private func layerPicker(allowsMixed: Bool) -> some View {
        Picker("", selection: $layerUUID) {
            if allowsMixed && loaded["layer"] == nil {
                Text("mixed").tag("")
            }
            ForEach(document.availableLayers) { layer in
                Text(layer.name).tag(layer.uuid)
            }
        }
        .labelsHidden()
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    // MARK: - Reading

    private func load() {
        problem = nil
        isConfirmingDelete = false
        regeneratesUUIDs = false
        if isBulk { loadShared() } else { loadOne() }
        loadModes()
    }

    /// The modes the GDTF lists for the type being edited, with whatever
    /// the fixtures are set to now kept in the list even if the GDTF
    /// doesn't name it — so opening the editor can never quietly change it.
    private func loadModes() {
        let specs = Set((isBulk ? fixtures : [fixture].compactMap { $0 }).map(\.gdtfSpec))
        guard specs.count == 1, let spec = specs.first,
              let data = document.gdtfFileData(forSpec: spec)
        else {
            modes = []
            return
        }
        var names = GDTFFootprintParser.modes(packageData: data).map(\.mode)
        let inUse = Set((isBulk ? fixtures : [fixture].compactMap { $0 })
            .map(\.mode).filter { $0 != "-" && !$0.isEmpty })
        for name in inUse.sorted() where !names.contains(name) { names.append(name) }
        modes = names
    }

    private func loadOne() {
        guard let fixture else { return }
        name = fixture.name
        fixtureID = fixture.currentFixtureID.map(String.init) ?? ""
        if let address = fixture.currentAddress {
            let split = MVRFixture.universeAndChannel(fromAbsoluteAddress: address)
            universe = String(split.universe)
            channel = String(split.channel)
        } else {
            universe = ""
            channel = ""
        }
        mode = fixture.mode == "-" ? "" : fixture.mode
        layerUUID = fixture.layerUUID
        uuid = fixture.currentUUID
    }

    /// A field shows its value only when every fixture shares it; where
    /// they differ it's left blank, and blank means "leave alone".
    private func loadShared() {
        func shared(_ value: (MVRFixture) -> String) -> String? {
            let values = Set(fixtures.map(value))
            return values.count == 1 ? values.first : nil
        }
        var values: [String: String] = [:]
        values["name"] = shared(\.name)
        values["universe"] = shared { fixture in
            fixture.currentAddress.map {
                String(MVRFixture.universeAndChannel(fromAbsoluteAddress: $0).universe)
            } ?? ""
        }
        values["mode"] = shared { $0.mode == "-" ? "" : $0.mode }
        values["layer"] = shared(\.layerUUID)
        loaded = values

        name = values["name"] ?? ""
        fixtureID = ""
        universe = values["universe"] ?? ""
        mode = values["mode"] ?? ""
        layerUUID = values["layer"] ?? ""
    }

    // MARK: - Writing

    /// Checks everything first and writes nothing unless all of it is good,
    /// so a typo in one field can't leave the fixture half-changed.
    private func apply(to fixture: MVRFixture) {
        let hasPatch = !universe.isEmpty || !channel.isEmpty
        var checks: [(MVRFixtureField, String)] = [(.name, name), (.uuid, uuid)]
        if !fixtureID.isEmpty { checks.append((.fixtureID, fixtureID)) }
        if hasPatch { checks += [(.universe, universe), (.channel, channel)] }
        if !mode.isEmpty || fixture.mode != "-" { checks.append((.mode, mode)) }
        guard passes(checks) else { return }

        let id = fixture.id
        if name != fixture.name { document.setName(name, forFixtureAtID: id) }
        if let number = Int(fixtureID), number != fixture.currentFixtureID {
            document.setFixtureID(number, forFixtureAtID: id)
        }
        if hasPatch, let u = Int(universe), let c = Int(channel) {
            let address = (u - 1) * 512 + c
            if address != fixture.currentAddress { document.setAddress(address, forFixtureAtID: id) }
        }
        if !mode.isEmpty, mode != fixture.mode { document.setGDTFMode(mode, forFixtureAtID: id) }
        setLayer(of: [fixture])
        if uuid != fixture.currentUUID { document.setUUID(uuid, forFixtureAtID: id) }
        onClose()
    }

    /// Only what was changed, on every fixture in the selection.
    private func applyToAll() {
        let targets = fixtures
        var checks: [(MVRFixtureField, String)] = []
        let nameChanged = !name.isEmpty && name != (loaded["name"] ?? "")
        let universeChanged = !universe.isEmpty && universe != (loaded["universe"] ?? "")
        let modeChanged = !mode.isEmpty && mode != (loaded["mode"] ?? "")
        if nameChanged { checks.append((.name, name)) }
        if !fixtureID.isEmpty { checks.append((.fixtureID, fixtureID)) }
        if universeChanged { checks.append((.universe, universe)) }
        guard passes(checks) else { return }

        if nameChanged {
            for fixture in targets { document.setName(name, forFixtureAtID: fixture.id) }
        }
        // Sequential IDs, in the order the fixtures are numbered now, so a
        // renumber keeps them in the same order.
        if let start = Int(fixtureID) {
            let ordered = targets.sorted {
                ($0.currentFixtureID ?? .max, $0.name) < ($1.currentFixtureID ?? .max, $1.name)
            }
            for (offset, fixture) in ordered.enumerated() {
                document.setFixtureID(start + offset, forFixtureAtID: fixture.id)
            }
        }
        if universeChanged, let number = Int(universe) {
            for fixture in targets {
                let channel = fixture.currentAddress
                    .map { MVRFixture.universeAndChannel(fromAbsoluteAddress: $0).channel } ?? 1
                document.setAddress((number - 1) * 512 + channel, forFixtureAtID: fixture.id)
            }
        }
        if modeChanged {
            for fixture in targets { document.setGDTFMode(mode, forFixtureAtID: fixture.id) }
        }
        setLayer(of: targets)
        if regeneratesUUIDs {
            for fixture in targets {
                document.setUUID(UUID().uuidString.lowercased(), forFixtureAtID: fixture.id)
            }
        }
        onClose()
    }

    private func setLayer(of targets: [MVRFixture]) {
        guard !layerUUID.isEmpty,
              let layer = document.availableLayers.first(where: { $0.uuid == layerUUID })
        else { return }
        for fixture in targets where fixture.layerUUID != layerUUID {
            document.setLayer(name: layer.name, uuid: layer.uuid, forFixtureAtID: fixture.id)
        }
    }

    private func passes(_ checks: [(MVRFixtureField, String)]) -> Bool {
        for (field, value) in checks {
            if let error = field.validate(value) {
                problem = "\(field.label): \(error)"
                return false
            }
        }
        return true
    }

    private func delete() {
        let ids = isBulk ? Set(fixtures.map(\.id)) : Set([fixture?.id].compactMap { $0 })
        document.deleteFixtures(withIDs: ids)
        onClose()
    }
}
