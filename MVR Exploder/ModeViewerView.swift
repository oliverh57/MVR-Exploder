import SwiftUI

/// What mode every fixture type in the rig is in, what that costs, and
/// changing it.
///
/// A health strip across the top answers "are my modes all right?" before
/// any row is read: how many types, how much DMX they take, and the
/// problems — a GDTF missing from the file, a type split across modes, a
/// mode its GDTF doesn't define — each a tile that filters to the types
/// with it. Those types come first in the list.
///
/// Each type is one row: its **mode ladder** — every mode its GDTF offers,
/// smallest to largest, the one in use filled in — and a **channel bar**
/// showing what the type takes out of the rig, to scale, so the heavy
/// types stand out. A mode changes by clicking its chip; each chip says
/// beforehand whether the patch would still fit, the change is one undo
/// step, and the footer says what it did.
struct ModeViewerView: View {
    @ObservedObject var document: MVRDocument
    let onBack: () -> Void

    enum Problem: CaseIterable, Hashable {
        case missingGDTF, standIn, unknownMode, split
    }

    /// Where a type's GDTF stands: the thing to see at a glance while
    /// working through a rig's stand-ins.
    enum GDTFStatus {
        /// Brought in from GDTF Share. The record is nil for a file named
        /// the way this app names GDTF Share downloads but saved before
        /// records were kept.
        case verified(MVRUserData.GDTFSource?)
        /// Real channels and attributes, from somewhere other than GDTF
        /// Share as far as this file knows.
        case full
        /// Made for the rig, not the fixture — Vectorworks' "Custom"
        /// GDTFs, this app's dummies, "Dummy" channels.
        case standIn
        case missing
    }

    enum Order: String, CaseIterable, Identifiable {
        case problemsFirst = "Problems First"
        case name = "Name"
        case channels = "Most Channels"
        var id: String { rawValue }
    }

    /// Each type's modes, read from its GDTF once on arrival. Nil while
    /// reading; a type missing from it has no readable GDTF.
    @State private var modesBySpec: [String: [GDTFFootprint]]?
    /// Mode names typed in that the GDTF doesn't define, per type.
    @State private var addedModes: [String: [String]] = [:]
    @State private var filterText = ""
    /// A health tile clicked to show only the types with that problem.
    @State private var problemFilter: Problem?
    @AppStorage("modeViewerOrder") private var order = Order.problemsFirst
    /// What moving every fixture of a type into each mode would do to the
    /// patch, by spec then mode. Worked out ahead, since each one runs the
    /// patch check over the whole rig.
    @State private var impacts: [String: [String: ModeSwapImpact]] = [:]
    /// The type "Other Mode…" is for.
    @State private var otherModeSpec: String?
    @State private var otherModeName = ""
    /// What the last change did, until the next.
    @State private var lastChange: String?
    /// The type whose GDTF is being replaced from GDTF Share.
    @State private var replacingSpec: String?

    var body: some View {
        let types = types
        VStack(spacing: 0) {
            ToolHeader("Mode Viewer", onBack: onBack)
            Divider()

            if modesBySpec == nil {
                ProgressView("Reading GDTFs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if types.isEmpty {
                Text("There are no fixtures in this file.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                healthStrip(types)
                Divider()
                typeList(types)
                Divider()
                footer
            }
        }
        // Read again whenever a type's GDTF changes — a replacement from
        // GDTF Share, or its undo.
        .task(id: Set(document.fixtures.map(\.gdtfSpec))) {
            modesBySpec = await document.loadFootprints()
        }
        .sheet(isPresented: Binding(
            get: { replacingSpec != nil },
            set: { if !$0 { replacingSpec = nil } })
        ) {
            if let spec = replacingSpec, let type = types.first(where: { $0.spec == spec }) {
                GDTFShareSheet(
                    document: document,
                    spec: spec,
                    typeName: type.name,
                    modesInUse: type.inUse.map { entry in
                        (entry.mode, entry.count, footprint(of: entry.mode, spec: spec).flatMap {
                            $0.isKnown ? Self.totalChannels($0) : nil
                        })
                    }
                ) { message in
                    replacingSpec = nil
                    if let message { lastChange = message }
                }
            }
        }
        .task(id: ImpactKey(edits: document.editCount, loaded: modesBySpec != nil, added: addedModes)) {
            await computeImpacts()
        }
        .alert("Another Mode", isPresented: Binding(
            get: { otherModeSpec != nil },
            set: { if !$0 { otherModeSpec = nil } })
        ) {
            TextField("Mode name", text: $otherModeName)
            Button("Change") { applyOtherMode() }
            Button("Cancel", role: .cancel) { otherModeName = "" }
        } message: {
            Text("A mode the GDTF doesn't define, typed exactly as the console expects it. Every fixture of the type moves to it.")
        }
    }

    private struct ImpactKey: Hashable {
        let edits: Int
        let loaded: Bool
        let added: [String: [String]]
    }

    // MARK: - The types

    struct TypeSummary: Identifiable {
        let spec: String
        let name: String
        let fixtures: [MVRFixture]
        /// Modes in use, most fixtures first.
        let inUse: [(mode: String, count: Int)]
        /// DMX channels the type takes, every break counted; nil when a
        /// mode in use has no known footprint.
        let channels: Int?
        /// grandMA3 parameters the type costs; nil when a mode in use
        /// has no known footprint.
        let parameters: Int?
        /// A mode in use has a stand-in GDTF, so `parameters` may count
        /// fine bytes that MA wouldn't.
        let hasPlaceholderGDTF: Bool
        let status: GDTFStatus
        let problems: Set<Problem>
        var id: String { spec }
    }

    private var types: [TypeSummary] {
        let bySpec: [String: [MVRFixture]] = Dictionary(grouping: document.fixtures, by: \.gdtfSpec)
        return bySpec.map { spec, fixtures in
            let byMode: [String: [MVRFixture]] = Dictionary(grouping: fixtures, by: \.mode)
            let inUse: [(mode: String, count: Int)] = byMode
                .map { (mode: $0.key, count: $0.value.count) }
                .sorted { first, second in
                    if first.count != second.count { return first.count > second.count }
                    return first.mode.localizedStandardCompare(second.mode) == .orderedAscending
                }

            var channels: Int? = 0
            var parameters: Int? = 0
            var placeholder = false
            for entry in inUse {
                if let footprint = footprint(of: entry.mode, spec: spec), footprint.isKnown {
                    if footprint.isPlaceholder { placeholder = true }
                    channels? += Self.totalChannels(footprint) * entry.count
                    if let perFixture = footprint.parameters {
                        parameters? += perFixture * entry.count
                    } else {
                        parameters = nil
                    }
                } else {
                    channels = nil
                    parameters = nil
                }
            }

            let defined = modesBySpec?[spec] ?? []
            let status: GDTFStatus
            if defined.isEmpty {
                status = .missing
            } else if placeholder || defined.allSatisfy(\.isPlaceholder) {
                status = .standIn
            } else if let source = document.gdtfSources[spec] {
                status = .verified(source)
            } else if Self.isGDTFShareName(spec) {
                status = .verified(nil)
            } else {
                status = .full
            }

            var problems: Set<Problem> = []
            switch status {
            case .missing: problems.insert(.missingGDTF)
            case .standIn: problems.insert(.standIn)
            case .verified, .full: break
            }
            if !defined.isEmpty, inUse.contains(where: { footprint(of: $0.mode, spec: spec) == nil }) {
                problems.insert(.unknownMode)
            }
            if inUse.count > 1 { problems.insert(.split) }

            return TypeSummary(
                spec: spec, name: GDTFSpecName.readable(spec), fixtures: fixtures,
                inUse: inUse, channels: channels, parameters: parameters,
                hasPlaceholderGDTF: placeholder, status: status, problems: problems)
        }
    }

    /// "Robe@Robin MegaPointe@r3038.gdtf": how a GDTF Share download is
    /// named, by this app and by others. Only trusted alongside real
    /// contents — a stand-in can carry the same shape of name.
    static func isGDTFShareName(_ spec: String) -> Bool {
        spec.range(of: #"@r\d+\.gdtf$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Every break, for what the type really takes out of the rig.
    private static func totalChannels(_ footprint: GDTFFootprint) -> Int {
        footprint.channelsByBreak.values.reduce(0, +)
    }

    private var query: String { filterText.trimmingCharacters(in: .whitespaces) }

    private func shown(_ types: [TypeSummary]) -> [TypeSummary] {
        types
            .filter { problemFilter.map($0.problems.contains) ?? true }
            .filter { type in
                query.isEmpty
                    || type.name.localizedCaseInsensitiveContains(query)
                    || type.spec.localizedCaseInsensitiveContains(query)
                    || type.inUse.contains { $0.mode.localizedCaseInsensitiveContains(query) }
            }
            .sorted { first, second in
                switch order {
                case .problemsFirst:
                    if first.problems.isEmpty != second.problems.isEmpty { return !first.problems.isEmpty }
                case .channels:
                    let a = first.channels ?? -1, b = second.channels ?? -1
                    if a != b { return a > b }
                case .name:
                    break
                }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    // MARK: - Health strip

    private func healthStrip(_ types: [TypeSummary]) -> some View {
        let missing = types.filter { $0.problems.contains(.missingGDTF) }.count
        let unknown = types.filter { $0.problems.contains(.unknownMode) }.count
        let split = types.filter { $0.problems.contains(.split) }.count
        let channels = types.compactMap(\.channels).reduce(0, +)
        let universes = Set(document.fixtures.compactMap { $0.currentAddress }.map {
            MVRFixture.universeAndChannel(fromAbsoluteAddress: $0).universe
        }).count

        return HStack(alignment: .top, spacing: 10) {
            HealthTile(
                value: "\(types.count)",
                caption: "fixture types · \(document.fixtures.count.formatted()) fixtures",
                symbol: "lightbulb.2")
            HealthTile(
                value: "\(channels.formatted()) ch",
                caption: "in use · \(universes) universe\(universes == 1 ? "" : "s") patched",
                symbol: "slider.horizontal.3")
            parameterTile(types)
            verifiedTile(types)
            if missing > 0 {
                problemTile(
                    .missingGDTF, count: missing,
                    problem: "\(missing) type\(missing == 1 ? "" : "s") with no GDTF",
                    fine: "",
                    symbol: "questionmark.folder")
            }
            problemTile(
                .split, count: split,
                problem: "\(split) type\(split == 1 ? "" : "s") split across modes",
                fine: "Each type in one mode",
                symbol: "square.split.2x1")
            if unknown > 0 {
                problemTile(
                    .unknownMode, count: unknown,
                    problem: "\(unknown) mode\(unknown == 1 ? "" : "s") not in its GDTF",
                    fine: "",
                    symbol: "exclamationmark.triangle")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// What the rig costs a grandMA3, and the smallest hardware that
    /// covers it — from MA's own table of parameters per device.
    private func parameterTile(_ types: [TypeSummary]) -> some View {
        let parameters = types.compactMap(\.parameters).reduce(0, +)
        let uncounted = types.filter { $0.parameters == nil }.count
        let placeholders = types.filter { $0.parameters != nil && $0.hasPlaceholderGDTF }.count
        var caption = "MA3 parameters · " + Self.hardware(for: parameters)
        if placeholders > 0 {
            caption += "\nAt most — \(placeholders) placeholder GDTF\(placeholders == 1 ? "" : "s")"
        }
        if uncounted > 0 { caption += "\n\(uncounted) type\(uncounted == 1 ? "" : "s") not counted" }
        return HealthTile(
            value: (placeholders > 0 ? "≤ " : "") + parameters.formatted(),
            caption: caption,
            symbol: "dial.medium",
            tint: uncounted > 0 ? .orange : .accentColor,
            captionLines: 3)
        .help("One parameter per attribute; a 16- or 24-bit channel's fine bytes are free, as MA counts them. "
            + "A placeholder GDTF lists every byte as its own channel, so for those types fine bytes can't be told apart "
            + "and the figure is an upper bound — a real GDTF makes it exact. Types without a GDTF can't be counted. "
            + "The console's System Info window gives the exact figure once patched.")
    }

    /// How many types have a genuine GDTF from GDTF Share, and how many are
    /// still on a stand-in — click to show just those, to work through them.
    private func verifiedTile(_ types: [TypeSummary]) -> some View {
        let verified = types.filter { if case .verified = $0.status { return true } else { return false } }.count
        let standIns = types.filter { $0.problems.contains(.standIn) }.count
        let isActive = problemFilter == .standIn
        return Button {
            guard standIns > 0 else { return }
            problemFilter = isActive ? nil : .standIn
        } label: {
            HealthTile(
                value: "\(verified) of \(types.count)",
                caption: standIns > 0
                    ? "verified from GDTF Share\n\(standIns) still on a stand-in GDTF"
                    : (verified == types.count ? "all verified from GDTF Share" : "verified from GDTF Share · no stand-ins"),
                symbol: "checkmark.seal",
                tint: standIns > 0 ? .orange : .green,
                isActive: isActive)
        }
        .buttonStyle(.plain)
        .help(standIns > 0
            ? (isActive ? "Show every type again." : "Show only the types still on a stand-in GDTF.")
            : "")
    }

    /// The smallest grandMA3 hardware with enough parameters, per MA's
    /// table: 4,096 (onPC wings, 4k nodes, PU M), 8,192 (compact, replay
    /// unit, PU L), 16,384 (light, PU XL), 20,480 (full-size).
    static func hardware(for parameters: Int) -> String {
        switch parameters {
        case ...4_096: return "fits 4,096 (onPC + wing or 4k node)"
        case ...8_192: return "needs 8,192 (compact, PU L)"
        case ...16_384: return "needs 16,384 (light, PU XL)"
        case ...20_480: return "needs 20,480 (full-size)"
        default: return "over 20,480 — add processing units"
        }
    }

    private func problemTile(
        _ kind: Problem, count: Int, problem: String, fine: String, symbol: String
    ) -> some View {
        let isActive = problemFilter == kind
        return Button {
            guard count > 0 else { return }
            problemFilter = isActive ? nil : kind
        } label: {
            HealthTile(
                value: count > 0 ? "\(count)" : "✓",
                caption: count > 0 ? problem : fine,
                symbol: symbol,
                tint: count > 0 ? .orange : .green,
                isActive: isActive)
        }
        .buttonStyle(.plain)
        .help(count > 0
            ? (isActive ? "Show every type again." : "Show only these types.")
            : "")
    }

    // MARK: - The list

    private func typeList(_ types: [TypeSummary]) -> some View {
        let rows = shown(types)
        let heaviest = types.compactMap(\.channels).max() ?? 1
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let problemFilter {
                    Button {
                        self.problemFilter = nil
                    } label: {
                        Label(filterTitle(problemFilter), systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }
                Text("\(rows.count) of \(types.count) types")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $order) {
                    ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                TextField("Search", text: $filterText, prompt: Text("Filter by type or mode"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { type in
                        typeRow(type, heaviest: heaviest)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private func filterTitle(_ problem: Problem) -> String {
        switch problem {
        case .missingGDTF: return "No GDTF"
        case .standIn: return "Stand-in GDTFs"
        case .unknownMode: return "Mode not in GDTF"
        case .split: return "Split across modes"
        }
    }

    private func typeRow(_ type: TypeSummary, heaviest: Int) -> some View {
        HStack(alignment: .center, spacing: 18) {
            identity(type)
                .frame(width: 230, alignment: .leading)
            ladder(type)
                .frame(maxWidth: .infinity, alignment: .leading)
            ChannelBar(channels: type.channels, parameters: type.parameters, heaviest: heaviest)
                .frame(width: 170)
        }
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            // A problem type carries an edge in the warning colour and a
            // verified one in green, so the list reads as "these first,
            // these done" without reading a word.
            if !type.problems.isEmpty {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                    .fill(Color.orange)
                    .frame(width: 4)
            } else if case .verified = type.status {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                    .fill(Color.green)
                    .frame(width: 4)
            }
        }
    }

    private func identity(_ type: TypeSummary) -> some View {
        let ids = Self.idRanges(type.fixtures.compactMap(\.currentFixtureID))
        let changed = type.fixtures.filter(\.isModeEdited)
        return VStack(alignment: .leading, spacing: 3) {
            Text(type.name)
                .font(.headline)
                .lineLimit(1)
                .help(type.spec)
            Text("\(type.fixtures.count) fixture\(type.fixtures.count == 1 ? "" : "s") · \(ids.short)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(ids.full)
            if type.problems.contains(.unknownMode) {
                Text("In a mode its GDTF doesn't define")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let first = changed.first {
                Text("Changed from \(display(first.originalMode))")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            HStack(spacing: 8) {
                GDTFStatusBadge(status: type.status)
                Button {
                    replacingSpec = type.spec
                } label: {
                    Label("GDTF Share…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.link)
                .font(.caption)
                .fixedSize()
                .help("Swap this type's GDTF for the full one from GDTF Share — every mode, the real channels and model.")
            }
        }
    }

    // MARK: - The ladder

    /// The modes the type could be in, smallest first — the GDTF's own
    /// names don't sort — with any in use but not defined, and any typed
    /// in, after them.
    private func ladderModes(_ type: TypeSummary) -> [String] {
        let defined = (modesBySpec?[type.spec] ?? []).sorted { first, second in
            let a = first.isKnown ? first.channels : Int.max
            let b = second.isKnown ? second.channels : Int.max
            if a != b { return a < b }
            return first.mode.localizedStandardCompare(second.mode) == .orderedAscending
        }
        // A mode with no DMX addresses can't be patched — Vectorworks'
        // template "Default" mode is one — so unless fixtures are in it,
        // it's left off.
        let inUse = Set(type.inUse.map(\.mode))
        var names = defined.filter { $0.isKnown || inUse.contains($0.mode) }.map(\.mode)
        for entry in type.inUse where !names.contains(entry.mode) { names.append(entry.mode) }
        for name in addedModes[type.spec] ?? [] where !names.contains(name) { names.append(name) }
        return names
    }

    private func ladder(_ type: TypeSummary) -> some View {
        let counts = Dictionary(type.inUse.map { ($0.mode, $0.count) }, uniquingKeysWith: +)
        let isSplit = type.inUse.count > 1
        let modes = ladderModes(type)
        // Exporters trim a file's GDTFs to the modes the rig uses — one
        // real file's thirteen types carry one or two modes each — so a
        // lone chip is usually all there is, and should say so.
        let hasNoOthers = !type.problems.contains(.missingGDTF) && modes.count == type.inUse.count
        return FlowLayout(spacing: 6) {
            ForEach(modes, id: \.self) { mode in
                let footprint = footprint(of: mode, spec: type.spec)
                let count = counts[mode]
                ModeChip(
                    title: display(mode),
                    detail: footprint.map(channelsLabel) ?? "?",
                    inUseCount: count,
                    showsCount: isSplit,
                    isUndefined: footprint == nil,
                    isChanged: count != nil && type.fixtures.contains { $0.mode == mode && $0.isModeEdited },
                    impact: count == type.fixtures.count ? nil : impacts[type.spec]?[mode]
                ) {
                    moveAll(of: type, to: mode)
                }
                .contextMenu {
                    chipMenu(type, mode: mode)
                }
            }
            Button {
                otherModeName = ""
                otherModeSpec = type.spec
            } label: {
                Label("Other…", systemImage: "plus")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("A mode the GDTF doesn't define.")
            if hasNoOthers {
                Text(modes.count == 1 ? "Only mode in the file's GDTF" : "Only modes in the file's GDTF")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 5)
                    .help("The GDTF inside this MVR lists no other modes. Exporters often leave out the modes a rig doesn't use.")
            }
        }
    }

    /// Right-click on a chip: move only one mode's worth into it, for a
    /// type split across modes.
    @ViewBuilder
    private func chipMenu(_ type: TypeSummary, mode: String) -> some View {
        let all = type.fixtures.filter { $0.mode != mode }
        if !all.isEmpty {
            Button("Move all \(all.count) to \(display(mode))") { moveAll(of: type, to: mode) }
        }
        let sources = type.inUse.filter { $0.mode != mode }
        if sources.count > 1 {
            Divider()
            ForEach(sources, id: \.mode) { source in
                Button("Move the \(source.count) in \(display(source.mode)) to \(display(mode))") {
                    change(Set(type.fixtures.filter { $0.mode == source.mode }.map(\.id)), to: mode)
                }
            }
        }
    }

    private func moveAll(of type: TypeSummary, to mode: String) {
        change(Set(type.fixtures.map(\.id)), to: mode)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(lastChange ?? "Click a mode to move the type to it. Green fits the patch as it stands; orange would clash. ⌘Z undoes a change.")
                .font(.caption)
                .foregroundStyle(lastChange == nil ? Color.secondary : Color.green)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Changing

    private func computeImpacts() async {
        guard let footprints = modesBySpec else { return }
        var found: [String: [String: ModeSwapImpact]] = [:]
        let all = document.fixtures
        for type in types {
            var byMode: [String: ModeSwapImpact] = [:]
            for mode in ladderModes(type) {
                let moving = Set(type.fixtures.filter { $0.mode != mode }.map(\.id))
                guard !moving.isEmpty else { continue }
                byMode[mode] = ModeSwapImpact.of(moving: moving, to: mode, fixtures: all, footprints: footprints)
            }
            found[type.spec] = byMode
            // Gives the window a turn on a big rig.
            await Task.yield()
            if Task.isCancelled { return }
        }
        impacts = found
    }

    private func applyOtherMode() {
        let name = otherModeName.trimmingCharacters(in: .whitespaces)
        defer {
            otherModeName = ""
            otherModeSpec = nil
        }
        guard let spec = otherModeSpec, !name.isEmpty else { return }
        if !(modesBySpec?[spec] ?? []).contains(where: { $0.mode == name }),
           !(addedModes[spec] ?? []).contains(name) {
            addedModes[spec, default: []].append(name)
        }
        change(Set(document.fixtures.filter { $0.gdtfSpec == spec }.map(\.id)), to: name)
    }

    private func change(_ ids: Set<String>, to mode: String) {
        let moving = document.fixtures.filter { ids.contains($0.id) && $0.mode != mode }
        guard !moving.isEmpty else { return }
        let impact = ModeSwapImpact.of(
            moving: Set(moving.map(\.id)), to: mode,
            fixtures: document.fixtures, footprints: modesBySpec ?? [:])
        document.setGDTFModes(Dictionary(uniqueKeysWithValues: moving.map { ($0.id, mode) }))
        lastChange = Self.describe(count: moving.count, mode: display(mode), impact: impact)
    }

    // MARK: - Wording

    private func footprint(of mode: String, spec: String) -> GDTFFootprint? {
        modesBySpec?[spec]?.first { $0.mode == mode }
    }

    private func display(_ mode: String) -> String {
        mode == "-" || mode.isEmpty ? "No mode" : mode
    }

    /// "117 ch", or "51 + 148 ch" for a mode spread over two breaks.
    private func channelsLabel(_ footprint: GDTFFootprint) -> String {
        guard footprint.isKnown else { return "?" }
        guard footprint.channelsByBreak.count > 1 else { return "\(footprint.channels) ch" }
        return footprint.channelsByBreak.keys.sorted()
            .compactMap { footprint.channelsByBreak[$0].map(String.init) }
            .joined(separator: " + ") + " ch"
    }

    /// "Moved 24 fixtures to Mode 2." and what it did to the patch.
    static func describe(count: Int, mode: String, impact: ModeSwapImpact) -> String {
        var text = "Moved \(count) fixture\(count == 1 ? "" : "s") to \(mode)."
        if impact.isChecked, impact.newOverlaps + impact.newOverruns > 0 {
            text += " \(clashText(impact))."
        }
        return text + " ⌘Z undoes it."
    }

    static func clashText(_ impact: ModeSwapImpact) -> String {
        var parts: [String] = []
        if impact.newOverlaps > 0 {
            parts.append("\(impact.newOverlaps) fixture\(impact.newOverlaps == 1 ? "" : "s") now overlap another's channels")
        }
        if impact.newOverruns > 0 {
            parts.append("\(impact.newOverruns) run past channel 512")
        }
        return parts.joined(separator: ", ") + " — re-patch them"
    }

    /// Fixture IDs as runs — "101–124, 130" — short enough for a row, with
    /// the whole list for its tooltip.
    static func idRanges(_ ids: [Int]) -> (short: String, full: String) {
        let sorted = Array(Set(ids)).sorted()
        guard let first = sorted.first else { return ("No IDs", "These fixtures have no Fixture IDs.") }
        var runs: [(Int, Int)] = []
        var start = first, end = first
        for id in sorted.dropFirst() {
            if id == end + 1 {
                end = id
            } else {
                runs.append((start, end))
                start = id
                end = id
            }
        }
        runs.append((start, end))
        let texts = runs.map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0)–\($0.1)" }
        let full = "IDs " + texts.joined(separator: ", ")
        let short = texts.count > 2
            ? "IDs " + texts.prefix(2).joined(separator: ", ") + " +\(texts.count - 2) more"
            : full
        return (short, full)
    }
}

/// One number worth knowing, and what it means.
private struct HealthTile: View {
    let value: String
    let caption: String
    let symbol: String
    var tint: Color = .accentColor
    var isActive = false
    var captionLines = 2

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint == .accentColor ? Color.primary : tint)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(captionLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minWidth: 150, maxWidth: 230, alignment: .leading)
        .background(tint == .orange ? Color.orange.opacity(0.12) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isActive ? tint : .clear, lineWidth: 2))
    }
}

/// One mode on a type's ladder. Filled when fixtures are in it; outlined
/// when they could be, with a mark saying whether the patch would take
/// the move.
private struct ModeChip: View {
    let title: String
    let detail: String
    /// Fixtures in this mode now; nil when none are.
    let inUseCount: Int?
    /// Show the count on the chip — only worth it for a split type.
    let showsCount: Bool
    let isUndefined: Bool
    let isChanged: Bool
    /// What moving the whole type here would do; nil when it's already
    /// all here or not yet worked out.
    let impact: ModeSwapImpact?
    let action: () -> Void

    @State private var isHovered = false

    private var isCurrent: Bool { inUseCount != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Text(detail)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                if let inUseCount, showsCount {
                    Text("×\(inUseCount)")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .background(Color.white.opacity(0.25), in: Capsule())
                }
                if !isCurrent, let impact { fitMark(impact) }
            }
            .font(.callout)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isCurrent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: isUndefined ? [3, 2] : [])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }

    private var fill: Color {
        if isUndefined { return .orange }
        return isChanged ? .blue : .accentColor
    }

    private var background: Color {
        if isCurrent { return fill.opacity(isUndefined ? 0.75 : 1) }
        return isHovered ? Color.primary.opacity(0.08) : .clear
    }

    private var border: Color {
        if isCurrent { return .clear }
        if isUndefined { return .orange }
        return Color.secondary.opacity(isHovered ? 0.6 : 0.3)
    }

    @ViewBuilder
    private func fitMark(_ impact: ModeSwapImpact) -> some View {
        let clashes = impact.newOverlaps + impact.newOverruns
        if impact.isChecked {
            if clashes == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("\(clashes)", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var help: String {
        if isCurrent {
            var text = inUseCount.map { "\($0) fixture\($0 == 1 ? "" : "s") in this mode." } ?? ""
            if isUndefined { text += " Its GDTF doesn't define it." }
            if showsCount { text += " Click to move the rest of the type here." }
            return text
        }
        guard let impact, impact.isChecked else {
            return "Click to move the type here. Its footprint isn't known, so the patch can't be checked."
        }
        let clashes = impact.newOverlaps + impact.newOverruns
        return clashes == 0
            ? "Click to move the type here — the patch still fits."
            : "Click to move the type here — \(ModeViewerView.clashText(impact))."
    }
}

/// What a type takes out of the rig, to scale against the heaviest type.
private struct ChannelBar: View {
    let channels: Int?
    let parameters: Int?
    let heaviest: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(channels.map { "\($0.formatted()) ch" } ?? "? ch")
                    .font(.callout.weight(.semibold).monospacedDigit())
                if let channels {
                    Text(String(format: "%.1f univ", Double(channels) / 512))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let parameters {
                    Text("· \(parameters.formatted()) par")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            GeometryReader { space in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let channels, heaviest > 0 {
                        Capsule()
                            .fill(Color.accentColor.gradient)
                            .frame(width: max(4, space.size.width * CGFloat(channels) / CGFloat(heaviest)))
                    }
                }
            }
            .frame(height: 6)
        }
        .help(channels.map {
            "This type takes \($0.formatted()) DMX channels in all"
                + (parameters.map { " and \($0.formatted()) grandMA3 parameters." } ?? ".")
        } ?? "Unknown — a mode in use has no footprint in its GDTF.")
    }
}

/// Lays chips out left to right, wrapping onto a new line when the row is
/// full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// What moving fixtures into another mode would do to the patch.
struct ModeSwapImpact: Equatable {
    /// Channels gained per fixture, negative for lost. Nil when the
    /// fixtures don't share one known footprint to compare from.
    var channelChange: Int?
    /// False when the new mode's footprint isn't known, so nothing could
    /// be checked.
    var isChecked: Bool
    /// Fixtures that would overlap another's channels and don't now —
    /// the moved ones and their neighbours alike.
    var newOverlaps: Int
    /// Fixtures that would run past channel 512 and don't now.
    var newOverruns: Int

    /// Checked with the same clash finder as the rest of the app, over
    /// every fixture in the file, before and after. Only what the swap
    /// would cause is counted: a clash that's there already isn't news.
    ///
    /// Footprints are taken at their word — not passed through the patch
    /// check's evenly-spaced-rig doubt. That doubt exists to spot a GDTF
    /// that disagrees with the rig; here the disagreement is the point,
    /// since a bigger mode on a rig spaced for a smaller one is exactly
    /// the clash worth warning about.
    static func of(
        moving ids: Set<String>, to mode: String,
        fixtures: [MVRFixture], footprints: [String: [GDTFFootprint]]
    ) -> ModeSwapImpact {
        func width(_ fixture: MVRFixture, in mode: String) -> Int? {
            guard let match = footprints[fixture.gdtfSpec]?.first(where: { $0.mode == mode }),
                  match.isKnown else { return nil }
            return match.channels
        }

        func patches(swapped: Bool) -> [MVRPatchCheck.Patch] {
            fixtures.compactMap { fixture in
                guard let address = fixture.currentAddress else { return nil }
                let moves = swapped && ids.contains(fixture.id)
                guard let footprint = width(fixture, in: moves ? mode : fixture.mode) else { return nil }
                let split = MVRFixture.universeAndChannel(fromAbsoluteAddress: address)
                return MVRPatchCheck.Patch(
                    fixtureID: fixture.id, name: fixture.name,
                    universe: split.universe, channel: split.channel, footprint: footprint)
            }
        }

        func flagged(_ patches: [MVRPatchCheck.Patch]) -> (overlaps: Set<String>, overruns: Set<String>) {
            var overlaps: Set<String> = []
            var overruns: Set<String> = []
            for finding in MVRPatchCheck.findings(in: patches) {
                switch finding {
                case let .overlap(_, _, fixtureIDs): overlaps.formUnion(fixtureIDs)
                case let .overrun(fixtureID, _, _): overruns.insert(fixtureID)
                }
            }
            return (overlaps, overruns)
        }

        let moving = fixtures.filter { ids.contains($0.id) }
        guard let newWidth = moving.first.flatMap({ width($0, in: mode) }) else {
            return ModeSwapImpact(channelChange: nil, isChecked: false, newOverlaps: 0, newOverruns: 0)
        }
        let oldWidths = Set(moving.map { width($0, in: $0.mode) })
        let change = oldWidths.count == 1 ? oldWidths.first.flatMap { $0 }.map { newWidth - $0 } : nil

        let before = flagged(patches(swapped: false))
        let after = flagged(patches(swapped: true))
        return ModeSwapImpact(
            channelChange: change,
            isChecked: true,
            newOverlaps: after.overlaps.subtracting(before.overlaps).count,
            newOverruns: after.overruns.subtracting(before.overruns).count)
    }
}

/// A type's GDTF status as a small coloured tag — green for a genuine GDTF
/// from GDTF Share, orange for a stand-in or a missing one.
private struct GDTFStatusBadge: View {
    let status: ModeViewerView.GDTFStatus

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(colour)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(colour.opacity(0.15), in: Capsule())
            .fixedSize()
            .help(help)
    }

    private var title: String {
        switch status {
        case .verified: return "GDTF Share"
        case .full: return "Full GDTF"
        case .standIn: return "Stand-in"
        case .missing: return "No GDTF"
        }
    }

    private var symbol: String {
        switch status {
        case .verified: return "checkmark.seal.fill"
        case .full: return "doc.text"
        case .standIn: return "exclamationmark.triangle.fill"
        case .missing: return "questionmark.folder"
        }
    }

    private var colour: Color {
        switch status {
        case .verified: return .green
        case .full: return .secondary
        case .standIn, .missing: return .orange
        }
    }

    private var help: String {
        switch status {
        case .verified(let source?):
            let by = source.isFromManufacturer ? "the manufacturer" : "a user"
            let date = source.modified.formatted(date: .abbreviated, time: .omitted)
            return "From GDTF Share: \(source.manufacturer) \(source.fixture), revision \(source.revision) — uploaded by \(by), updated \(date) (rid \(source.rid))."
        case .verified(nil):
            return "Named as a GDTF Share download and carries real channels, but the file has no record of the revision."
        case .full:
            return "A real GDTF — real channels and attributes — but not one this file records as coming from GDTF Share."
        case .standIn:
            return "A stand-in made for the rig, not the fixture: the right number of channels, but not what they do. Replace it from GDTF Share."
        case .missing:
            return "The file has no GDTF for this type, so its modes are unknown."
        }
    }
}
