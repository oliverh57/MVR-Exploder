import SwiftUI

/// Every fixture type, the modes its GDTF offers, and moving fixtures
/// between them.
///
/// Types down the side; the chosen type's modes on the right, every one on
/// show with its footprint, so there's no menu to open to see what a type
/// could be in. A mode is mostly a channel count, and what a swap puts at
/// risk is the patch — so picking a mode says what the swap would do before
/// it's made: the change in channels, and any fixture it would push onto
/// another's channels or off the end of its universe.
///
/// A swap moves a group in one go and one undo step. A mode the GDTF
/// doesn't have can be added by name.
struct ModeSwapView: View {
    @ObservedObject var document: MVRDocument
    let onBack: () -> Void

    /// Each type's modes, read from its GDTF once on arrival. Nil while
    /// reading; a type missing from it has no readable GDTF.
    @State private var modesBySpec: [String: [GDTFFootprint]]?
    /// Mode names added here that the GDTF doesn't define, per type.
    @State private var addedModes: [String: [String]] = [:]
    @State private var selectedSpec: String?
    /// The mode picked to move fixtures into.
    @State private var target: String?
    /// The mode to move fixtures out of; nil moves every fixture of the
    /// type that isn't in the target already.
    @State private var source: String?
    @State private var newModeName = ""
    /// What the last swap did, until the next mode is picked.
    @State private var lastSwap: String?

    var body: some View {
        let types = types
        VStack(spacing: 0) {
            ToolHeader("Mode Swap", onBack: onBack)
            Divider()

            if modesBySpec == nil {
                ProgressView("Reading GDTFs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if types.isEmpty {
                Text("There are no fixtures in this file.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    sidebar(types)
                        .frame(width: 270)
                    Divider()
                    if let type = types.first(where: { $0.spec == selectedSpec }) {
                        detail(type)
                    } else {
                        Text("Pick a fixture type.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task {
            guard modesBySpec == nil else { return }
            modesBySpec = await document.loadFootprints()
        }
        .onChange(of: selectedSpec) { _, _ in
            target = nil
            source = nil
            newModeName = ""
            lastSwap = nil
        }
    }

    // MARK: - The types

    private struct TypeSummary: Identifiable {
        let spec: String
        let name: String
        let fixtures: [MVRFixture]
        /// Modes in use, most fixtures first.
        let inUse: [(mode: String, count: Int)]
        /// Some fixture of this type isn't in the mode the file opened with.
        let isChanged: Bool
        var id: String { spec }
    }

    private var types: [TypeSummary] {
        let bySpec: [String: [MVRFixture]] = Dictionary(grouping: document.fixtures, by: \.gdtfSpec)
        return bySpec.map(summary)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func summary(spec: String, fixtures: [MVRFixture]) -> TypeSummary {
        let byMode: [String: [MVRFixture]] = Dictionary(grouping: fixtures, by: \.mode)
        let inUse: [(mode: String, count: Int)] = byMode
            .map { (mode: $0.key, count: $0.value.count) }
            .sorted { first, second in
                if first.count != second.count { return first.count > second.count }
                return first.mode.localizedStandardCompare(second.mode) == .orderedAscending
            }
        return TypeSummary(
            spec: spec,
            name: GDTFSpecName.readable(spec),
            fixtures: fixtures,
            inUse: inUse,
            isChanged: fixtures.contains(where: \.isModeEdited))
    }

    private func sidebar(_ types: [TypeSummary]) -> some View {
        List(types, selection: $selectedSpec) { type in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(type.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if type.isChanged {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .help("A mode here has changed since the file was opened.")
                    }
                    Spacer(minLength: 4)
                    Text("\(type.fixtures.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(modesInUse(type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 3)
        }
        .listStyle(.sidebar)
        .onAppear {
            if selectedSpec == nil { selectedSpec = types.first?.spec }
        }
    }

    private func modesInUse(_ type: TypeSummary) -> String {
        guard type.inUse.count == 1, let only = type.inUse.first else {
            return "\(type.inUse.count) modes"
        }
        guard let footprint = footprint(of: only.mode, spec: type.spec), footprint.isKnown else {
            return display(only.mode)
        }
        return "\(display(only.mode))  ·  \(channelsLabel(footprint))"
    }

    // MARK: - One type's modes

    private struct ModeOption: Identifiable {
        let name: String
        /// Nil when the GDTF doesn't define this mode.
        let footprint: GDTFFootprint?
        let inUse: Int
        let isAdded: Bool
        var id: String { name }
    }

    /// The modes fixtures are in now, then the rest of the GDTF's smallest
    /// first, then any added here. Smallest first because a mode is mostly
    /// a footprint, and the GDTF's own names don't sort — "DMX Mode 6"
    /// before "Mode 1".
    private func options(for type: TypeSummary) -> (inUse: [ModeOption], others: [ModeOption]) {
        let defined = modesBySpec?[type.spec] ?? []
        let counts = Dictionary(type.inUse.map { ($0.mode, $0.count) }, uniquingKeysWith: +)

        let inUse = type.inUse.map { entry in
            ModeOption(
                name: entry.mode, footprint: defined.first { $0.mode == entry.mode },
                inUse: entry.count, isAdded: false)
        }
        var listed = Set(inUse.map(\.name))
        var others = defined
            .filter { listed.insert($0.mode).inserted }
            .sorted { first, second in
                let a = first.isKnown ? first.channels : Int.max
                let b = second.isKnown ? second.channels : Int.max
                if a != b { return a < b }
                return first.mode.localizedStandardCompare(second.mode) == .orderedAscending
            }
            .map { ModeOption(name: $0.mode, footprint: $0, inUse: counts[$0.mode] ?? 0, isAdded: false) }
        for name in addedModes[type.spec] ?? [] where listed.insert(name).inserted {
            others.append(ModeOption(name: name, footprint: nil, inUse: 0, isAdded: true))
        }
        return (inUse, others)
    }

    private func detail(_ type: TypeSummary) -> some View {
        let (inUse, others) = options(for: type)
        // Whether the patch as it stands could take each mode — the thing
        // to know before picking one. Every fixture of the type moving,
        // as the swap would by default.
        let impacts = Dictionary(uniqueKeysWithValues: others.map { option in
            (option.name, ModeSwapImpact.of(
                moving: Set(type.fixtures.filter { $0.mode != option.name }.map(\.id)),
                to: option.name, fixtures: document.fixtures, footprints: modesBySpec ?? [:]))
        })

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(type.name)
                    .font(.title3.weight(.semibold))
                Text("\(type.spec)  ·  \(type.fixtures.count) fixture\(type.fixtures.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionTitle("In use")
                    ForEach(inUse) { option in
                        inUseRow(option, in: type)
                    }

                    sectionTitle(others.isEmpty ? "No other modes" : "Swap to")
                        .padding(.top, 10)
                    if (modesBySpec?[type.spec] ?? []).isEmpty {
                        Label("This type's GDTF isn't in the file, so its modes aren't known. "
                              + "A mode can still be added by name.",
                              systemImage: "questionmark.folder")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(others) { option in
                        modeRow(option, in: type, impact: impacts[option.name])
                    }
                    newModeRow(type)
                }
                .padding(8)
            }

            Divider()
            actionBar(type)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    /// A mode fixtures are in now, shown at full strength — it's the row
    /// that matters most. Offers to gather the rest of the type into it
    /// when the type is split across modes.
    private func inUseRow(_ option: ModeOption, in type: TypeSummary) -> some View {
        let isTarget = target == option.name
        let canMoveIn = option.inUse < type.fixtures.count

        return HStack(spacing: 10) {
            Image(systemName: isTarget ? "arrow.right.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isTarget ? Color.accentColor : Color.green)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 1) {
                Text(display(option.name))
                    .fontWeight(.semibold)
                Text("\(option.inUse) fixture\(option.inUse == 1 ? "" : "s")"
                     + (option.footprint == nil ? " — not in the GDTF" : ""))
                    .font(.caption)
                    .foregroundStyle(option.footprint == nil ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 12)
            if canMoveIn {
                Button("Move Others Here") { pick(option.name) }
                    .controlSize(.small)
            }
            channels(option.footprint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isTarget ? Color.accentColor.opacity(0.15) : Color.green.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// A mode to swap to: its size, the change from now, and whether the
    /// patch as it stands would take it.
    private func modeRow(_ option: ModeOption, in type: TypeSummary, impact: ModeSwapImpact?) -> some View {
        let isTarget = target == option.name

        return Button {
            pick(isTarget ? nil : option.name)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isTarget ? "arrow.right.circle.fill" : "circle")
                    .foregroundStyle(isTarget ? Color.accentColor : Color.secondary)
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 1) {
                    Text(display(option.name))
                    if option.footprint == nil {
                        Text(option.isAdded ? "Added here — not in the GDTF" : "Not in the GDTF")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 12)

                if let impact { fit(impact) }
                change(impact?.channelChange)
                channels(option.footprint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isTarget ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(impact.map(fitHelp) ?? "")
    }

    /// Fits, or how many fixtures would clash.
    private func fit(_ impact: ModeSwapImpact) -> some View {
        let clashes = impact.newOverlaps + impact.newOverruns
        return Group {
            if !impact.isChecked {
                Text("Can't check")
                    .foregroundStyle(.secondary)
            } else if clashes == 0 {
                Label("Fits", systemImage: "checkmark")
                    .foregroundStyle(.green)
            } else {
                Label("\(clashes) clash\(clashes == 1 ? "" : "es")", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .frame(width: 100, alignment: .leading)
    }

    private func fitHelp(_ impact: ModeSwapImpact) -> String {
        guard impact.isChecked else { return "This mode's footprint isn't known, so the patch can't be checked." }
        if impact.newOverlaps + impact.newOverruns == 0 {
            return "Every fixture of this type could move here without re-patching."
        }
        return clashText(impact)
    }

    private func change(_ change: Int?) -> some View {
        Text(change.map { $0 == 0 ? "±0" : "\($0 > 0 ? "+" : "−")\(abs($0))" } ?? "")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
    }

    private func channels(_ footprint: GDTFFootprint?) -> some View {
        Text(footprint.map { $0.isKnown ? channelsLabel($0) : "?" } ?? "")
            .monospacedDigit()
            .frame(width: 84, alignment: .trailing)
    }

    private func pick(_ mode: String?) {
        target = mode
        source = nil
        lastSwap = nil
    }

    private func newModeRow(_ type: TypeSummary) -> some View {
        let name = newModeName.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .imageScale(.large)
            TextField("Add a mode the GDTF doesn't have…", text: $newModeName)
                .textFieldStyle(.plain)
                .onSubmit { addMode(name, to: type) }
            if !name.isEmpty {
                Button("Add") { addMode(name, to: type) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - The swap

    private func actionBar(_ type: TypeSummary) -> some View {
        HStack(spacing: 12) {
            if let target, let moving = moving(in: type, to: target), !moving.isEmpty {
                let impact = ModeSwapImpact.of(
                    moving: Set(moving), to: target,
                    fixtures: document.fixtures, footprints: modesBySpec ?? [:])
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(moving.count) fixture\(moving.count == 1 ? "" : "s") → \(Text(display(target)).fontWeight(.semibold))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    impactLine(impact)
                }
                Spacer(minLength: 8)
                sourcePicker(type, target: target)
                Button("Swap \(moving.count) Fixture\(moving.count == 1 ? "" : "s")") {
                    swap(moving, of: type, to: target)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text(lastSwap ?? "Pick a mode to move this type's fixtures into it.")
                    .foregroundStyle(lastSwap == nil ? Color.secondary : Color.green)
                Spacer()
            }
        }
        .padding(12)
        .frame(minHeight: 58)
    }

    /// The fixtures a swap would move: those of this type not already in
    /// the target, narrowed to one mode when a source is picked.
    private func moving(in type: TypeSummary, to target: String) -> [String]? {
        let liveSource = type.inUse.contains { $0.mode == source } ? source : nil
        return type.fixtures
            .filter { $0.mode != target && (liveSource == nil || $0.mode == liveSource) }
            .map(\.id)
    }

    /// Only for a type split across modes: move all of them, or one
    /// mode's worth.
    @ViewBuilder
    private func sourcePicker(_ type: TypeSummary, target: String) -> some View {
        let sources = type.inUse.filter { $0.mode != target }
        if sources.count > 1 {
            Picker("From", selection: $source) {
                Text("From all modes").tag(String?.none)
                ForEach(sources, id: \.mode) { entry in
                    Text("From \(display(entry.mode)) (\(entry.count))").tag(Optional(entry.mode))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private func impactLine(_ impact: ModeSwapImpact) -> some View {
        HStack(spacing: 10) {
            if let change = impact.channelChange {
                Text(change == 0 ? "Same footprint"
                     : "\(change > 0 ? "+" : "−")\(abs(change)) ch each")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !impact.isChecked {
                Text("New footprint unknown, so the patch can't be checked.")
                    .foregroundStyle(.secondary)
            } else if impact.newOverlaps == 0 && impact.newOverruns == 0 {
                Label("The patch still fits", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label(clashText(impact), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    private func clashText(_ impact: ModeSwapImpact) -> String {
        var parts: [String] = []
        if impact.newOverlaps > 0 {
            parts.append("\(impact.newOverlaps) fixture\(impact.newOverlaps == 1 ? "" : "s") would overlap another's channels")
        }
        if impact.newOverruns > 0 {
            parts.append("\(impact.newOverruns) would run past channel 512")
        }
        return parts.joined(separator: ", ") + " — re-patch after swapping"
    }

    private func swap(_ moving: [String], of type: TypeSummary, to mode: String) {
        document.setGDTFModes(Dictionary(uniqueKeysWithValues: moving.map { ($0, mode) }))
        lastSwap = "Moved \(moving.count) \(type.name) to \(display(mode)). ⌘Z undoes it."
        target = nil
        source = nil
    }

    private func addMode(_ name: String, to type: TypeSummary) {
        guard !name.isEmpty else { return }
        let (inUse, others) = options(for: type)
        if !(inUse + others).contains(where: { $0.name == name }) {
            addedModes[type.spec, default: []].append(name)
        }
        newModeName = ""
        target = name
        source = nil
        lastSwap = nil
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
        guard footprint.channelsByBreak.count > 1 else { return "\(footprint.channels) ch" }
        return footprint.channelsByBreak.keys.sorted()
            .compactMap { footprint.channelsByBreak[$0].map(String.init) }
            .joined(separator: " + ") + " ch"
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
