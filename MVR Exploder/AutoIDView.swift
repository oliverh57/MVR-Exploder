import SwiftUI

/// Preview and tune an auto-ID run before anything is written.
///
/// Nothing here touches the document until Apply. Clustering is a guess —
/// it convinces for roughly two thirds of fixture types on real files — so
/// the groups it found are shown per type and can be merged or split by
/// hand before the numbers are committed.
struct AutoIDView: View {
    @ObservedObject var session: AutoIDSession
    let onCancel: () -> Void
    let onApply: () -> Void
    @State private var selectedSpecs: Set<String> = []

    /// The type being worked on. Multiple selection exists only for
    /// merging; every other pane needs exactly one type to talk about.
    private var selectedSpec: String? {
        selectedSpecs.count == 1 ? selectedSpecs.first : nil
    }
    @State private var selectedGroups: Set<Int> = []
    @State private var showChanges = false
    /// Incremented to replay the numbering order in the preview.
    @State private var playToken = 0
    @State private var autoPlayTask: Task<Void, Never>?
    /// Armed by "Draw split", so a drag in the preview cuts instead of orbiting.
    @State private var isDrawingSplit = false
    @State private var previewMode: PreviewMode = .space
    /// The group being renamed, and the text field's contents while it is.
    @State private var renamingGroup: Int?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool
    @State private var showTolerance = false
    /// The group whose own spacing is being adjusted, held by membership
    /// rather than row index: dragging the slider re-splits that group, so
    /// the row it came from stops existing part-way through.
    @State private var spacingTarget: Set<String>?
    /// The family row whose linked-types popover is open.
    @State private var linkedTypesRow: String?
    /// Where in the preview a right-click asked for the group menu.
    @State private var menuAnchor: CGPoint?
    /// Set when the "pick an order" warning is clicked, so the same menu
    /// opens from the row that raised it.
    @State private var warningMenuGroup: Int?

    /// What a "Set starting ID" dialog is editing.
    private enum PinTarget: Equatable {
        case type(String)
        case group(index: Int, spec: String)
    }
    @State private var pinTarget: PinTarget?
    /// Set when closing would lose work and the user hasn't said yes yet.
    @State private var isConfirmingCancel = false
    @State private var pinText = ""
    /// Set after a pin creates clashes, holding what to put back if the
    /// user decides against it.
    @State private var pinClash: (target: PinTarget, previous: Int?, count: Int)?
    @State private var hoveredFixtureID: String?
    @State private var hoverPoint: CGPoint = .zero

    /// The two questions a run raises, which need different pictures: where
    /// the fixtures are and which way the numbers run through them, and what
    /// the resulting patch looks like laid out by ID.
    private enum PreviewMode: String, CaseIterable, Identifiable {
        case space
        case idMap

        var id: String { rawValue }

        var label: String { self == .space ? "3D" : "ID map" }
        var symbol: String { self == .space ? "cube.transparent" : "square.grid.3x3" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            explainer
            Divider()
            HStack(spacing: 0) {
                typeList
                Divider()
                groupsPane
                    .frame(width: 330)
                Divider()
                preview
            }
            Divider()
            footer
        }
        .frame(width: 1280, height: 760)
        // Escape is routed through `requestCancel` by the Cancel button's
        // shortcut instead of quietly dismissing the sheet, which threw
        // away a whole sitting's merges, orders and names with no warning.
        .interactiveDismissDisabled()
        .alert("Discard this Smart Auto ID run?", isPresented: $isConfirmingCancel) {
            Button("Discard", role: .destructive) { onCancel() }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text("The groups, orders, names and starting IDs you've set here "
                 + "will be lost. Nothing has been written to the file yet.")
        }
        .onAppear {
            if selectedSpecs.isEmpty, let first = session.displayTypes.first { selectedSpecs = [first] }
        }
        // Anything that changes what would be numbered, or which part of it
        // is being looked at, replays the order.
        .onChange(of: selectedGroups) { _, _ in
            // Looking at a group answers its warning. The route it chose is
            // shown on the row, so having selected it you have seen it.
            if let spec = selectedSpec {
                for index in selectedGroups { session.acknowledge(groupIndex: index, in: spec) }
            }
            if selectedGroups.count != 1 { isDrawingSplit = false; showTolerance = false }
            // Only when one group is in hand. Assembling a selection to
            // merge is not inspecting an order, and replaying four seconds
            // of flashes over a few hundred fixtures on every Control-click
            // is what made picking several groups feel slow.
            guard selectedGroups.count == 1 else { return }
            scheduleAutoPlay()
        }
        .onChange(of: selectedSpecs) { _, _ in
            isDrawingSplit = false
            selectedGroups = []
            scheduleAutoPlay()
        }
        .onChange(of: session.revision) { _, _ in scheduleAutoPlay() }
        // Drawing a split needs the 3D view under the cursor.
        .onChange(of: previewMode) { _, _ in
            isDrawingSplit = false
            // The 3D view stays mounted behind the map and gets no exit
            // event when it's covered, so its last card would hang around.
            hoveredFixtureID = nil
        }
        .onDisappear { autoPlayTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Text("Smart Auto ID")
                .font(.headline)

            Divider().frame(height: 20)

            HStack(spacing: 6) {
                Text("Start at")
                TextField("", value: $session.startingID, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }

            Divider().frame(height: 20)

            gapControls


            Divider().frame(height: 20)

            Button {
                session.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!session.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Step back through merges, splits and settings.")

            Button {
                session.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!session.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Spacer()

            attentionSummary

            Text("\(session.plan.changedCount) of \(session.plan.assignments.count) IDs change")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// Spare IDs left in the numbering, so a fixture added later can be
    /// slotted in without renumbering the rig behind it.
    ///
    /// The two are separate tickboxes rather than one setting because they
    /// solve different problems: room at the end of a truss, and room
    /// between two fixtures already on it. Most shows want the first only.
    private var gapControls: some View {
        HStack(spacing: 10) {
            gapControl(
                title: "Gap between groups",
                isOn: $session.gaps.betweenGroups,
                value: $session.gaps.groupGap,
                help: "Leave this many spare IDs after each group, so a "
                    + "fixture added to a truss later doesn't push the rest along.")
            gapControl(
                title: "Gap between fixtures",
                isOn: $session.gaps.betweenFixtures,
                value: $session.gaps.fixtureGap,
                help: "Leave this many spare IDs after each fixture — a gap of 1 "
                    + "numbers 1001, 1003, 1005, leaving room to slot one in between.")
        }
    }

    private func gapControl(
        title: String, isOn: Binding<Bool>, value: Binding<Int>, help: String
    ) -> some View {
        HStack(spacing: 5) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                // Left visible rather than hidden when off, so the number
                // it would use is readable before ticking the box.
                .disabled(!isOn.wrappedValue)
                .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
        }
        .help(help)
    }

    /// What the tool is doing, in one line. Without it "groups" and the ID
    /// ranges in the type list are just numbers on first sight.
    private var explainer: some View {
        HStack(spacing: 8) {
            if session.restoredFromFile {
                Image(systemName: "clock.arrow.circlepath")
                Text("Picked up where you left off — this file carries an earlier run. "
                     + "Groups, orders and names are as you left them.")
                Button("Start fresh") { session.startFresh() }
                    .buttonStyle(.link)
            } else {
                Text("Fixtures are grouped into positions — trusses, towers, floor packages — "
                     + "and numbered along each in turn. Every fixture type gets its own block of IDs.")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// Points at the types worth opening, so checking the run is a short
    /// list rather than an unbounded audit.
    @ViewBuilder
    private var attentionSummary: some View {
        let targets = attentionTargets
        let flagged = orderedUnique(targets.map(\.spec))
        if flagged.isEmpty {
            Label("Every group is a straight run", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // A button, not a label: saying a type needs a look and leaving
            // the user to find which group is half an answer. Each click
            // takes the next one, so the flagged groups can be worked
            // through without hunting for them — and selecting a group is
            // what marks it seen, so the count comes down as you go.
            Button {
                goToNextGroupNeedingAttention(targets)
            } label: {
                Label(
                    flagged.count == 1 ? "1 type needs a look" : "\(flagged.count) types need a look",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("\(targets.count) group\(targets.count == 1 ? "" : "s") with a shape that has "
                  + "no obvious order. Click to go to the next one:\n"
                  + flagged.map { session.displayName(for: $0) }.joined(separator: "\n"))
        }
    }

    /// Every group still waiting to be looked at, in list order.
    private var attentionTargets: [(spec: String, group: Int)] {
        session.displayTypes
            .filter { session.includedTypes.contains($0) }
            .flatMap { spec in
                (session.plan.groupsBySpec[spec] ?? []).indices
                    .filter { session.needsAttention(groupIndex: $0, in: spec) }
                    .map { (spec: spec, group: $0) }
            }
    }

    /// Selects the next flagged group after whatever is selected now, so
    /// repeated clicks walk the list rather than sticking on the first one.
    private func goToNextGroupNeedingAttention(_ targets: [(spec: String, group: Int)]) {
        guard !targets.isEmpty else { return }
        let current = selectedSpec
        let selected = selectedGroups.count == 1 ? selectedGroups.first : nil
        let next = targets.first { $0.spec != current || $0.group != selected } ?? targets[0]
        focus(spec: next.spec, group: next.group)
    }

    /// What Escape and the Cancel button do.
    ///
    /// Escape means "back out of the thing I'm in", so anything open in the
    /// sheet closes first and only a press with nothing open is treated as
    /// closing the tool. Without that, taking Escape over for the sheet
    /// would have stopped it cancelling a rename, which is what it did
    /// before.
    private func requestCancel() {
        if renamingGroup != nil { renamingGroup = nil; return }
        if isDrawingSplit { isDrawingSplit = false; return }
        if showTolerance { showTolerance = false; return }
        if pinTarget != nil { pinTarget = nil; return }

        // Nothing done, nothing to lose — asking would just be a keypress
        // in the way.
        guard session.hasUnsavedWork else {
            onCancel()
            return
        }
        isConfirmingCancel = true
    }

    /// Selects one group, switching type if it belongs to another one.
    ///
    /// The two cannot be set in one go: `onChange(of: selectedSpecs)`
    /// clears the group selection, so a group set at the same time as a new
    /// type lands and is wiped a moment later.
    private func focus(spec: String, group: Int) {
        guard selectedSpecs != [spec] else {
            selectedGroups = [group]
            return
        }
        selectedSpecs = [spec]
        DispatchQueue.main.async { selectedGroups = [group] }
    }

    /// First occurrence wins, order kept — `Set` would scramble the types.
    private func orderedUnique(_ specs: [String]) -> [String] {
        var seen: Set<String> = []
        return specs.filter { seen.insert($0).inserted }
    }

    /// The types numbered as one, each tickable so a single one can be
    /// taken out without breaking up the rest of the family.
    private func linkedTypesPanel(members: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Numbered as one type")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(members, id: \.self) { member in
                Toggle(isOn: Binding(
                    get: { true },
                    set: { isOn in
                        guard !isOn else { return }
                        // Unticking the last pair separates the family
                        // outright, so the popover has nothing left to show.
                        if members.count <= 2 { linkedTypesRow = nil }
                        session.unlink(member)
                    })
                ) {
                    Text(session.displayName(ofType: member))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(member)
                }
                .toggleStyle(.checkbox)
            }

            Divider()

            Text("\(session.fixtureCount(of: members[0])) fixtures share one block of IDs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    /// One blob's own clustering distance.
    ///
    /// For a file that groups well except in one place: the type-wide
    /// slider would fix that blob and ruin everything else, so this splits
    /// only the group it was opened from and leaves the rest untouched.
    private func groupSpacingControls(key: Set<String>) -> some View {
        let range = session.groupSpacingRange(forKey: key)
        let current = session.groupSpacing(forKey: key) ?? session.automaticGroupSpacing(forKey: key)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Spacing for this group only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Auto") { session.setGroupSpacing(nil, forKey: key) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(session.groupSpacing(forKey: key) == nil)
            }

            if let range {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: {
                            spacingPosition(
                                session.groupSpacing(forKey: key) ?? session.automaticGroupSpacing(forKey: key),
                                in: range)
                        },
                        set: { session.setGroupSpacing(spacingValue($0, in: range), forKey: key) }
                    ), in: 0...1)

                    Text(String(format: "%.2f m", current))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                Text("\(key.count) fixtures · splits into \(splitCount(key: key)) groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Too few fixtures here to divide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    /// How many groups this blob currently divides into.
    private func splitCount(key: Set<String>) -> Int {
        guard let spec = selectedSpec else { return 1 }
        return session.groups(for: spec).filter { members in
            members.contains { key.contains($0.id) }
        }.count
    }

    /// Per type, because it decides where one group ends and the next
    /// begins — a question about the rig's layout, not about any one group.
    ///
    /// The automatic figure comes from the type's median spacing, which a
    /// real rig routinely breaks: fixtures hung in tight pairs up a tower
    /// cluster as pairs, where the user sees four towers. Widening this
    /// merges them; narrowing it breaks a long run apart.
    private func spacingControls(spec: String, range: ClosedRange<Double>) -> some View {
        let current = session.groupingDistance(for: spec)
        let position = Binding(
            get: { spacingPosition(session.groupingDistance(for: spec), in: range) },
            set: {
                // Group indices mean something different either side of a
                // change, so a held selection would follow the row number
                // onto a different group.
                if !selectedGroups.isEmpty { selectedGroups = [] }
                session.setGroupingDistance(spacingValue($0, in: range), for: spec)
            })

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Grouping distance — how far apart fixtures must be to be a separate truss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button("Auto") { session.resetGroupingDistance(for: spec) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(!session.hasCustomGroupingDistance(for: spec))
            }

            HStack(spacing: 8) {
                Slider(value: position, in: 0...1)
                    .help("Left splits the type into more, smaller groups; right merges them into fewer, larger ones.\n\nSetting this by hand also turns off the automatic truss detection for this type, since the two would fight. Use Auto to get it back.")

                // The count is the answer to what the drag was for, so it
                // sits under the thumb rather than only in the list below.
                Text(String(format: "%.2f m · %d", current, session.groups(for: spec).count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Slider travel is logarithmic. The range runs from the tightest pair
    /// in the type to the gap that swallows the whole rig — often a factor
    /// of a hundred — and on a linear scale every grouping that matters
    /// would sit within the first few millimetres of travel.
    private func spacingPosition(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = log(range.upperBound / range.lowerBound)
        guard span > 0 else { return 0 }
        return min(1, max(0, log(max(value, range.lowerBound) / range.lowerBound) / span))
    }

    private func spacingValue(_ position: Double, in range: ClosedRange<Double>) -> Double {
        range.lowerBound * pow(range.upperBound / range.lowerBound, min(1, max(0, position)))
    }

    /// Per group, because how much a position wanders belongs to that
    /// position: one real U had a leg spanning 13cm across while the other
    /// leg was exact to the millimetre, and a single figure for the file
    /// can't suit both. A column read as several separate ones gets
    /// numbered in the wrong order.
    private func toleranceControls(index: Int, spec: String) -> some View {
        let current = session.tolerance(forGroup: index, in: spec)
        func binding(_ keyPath: WritableKeyPath<AutoIDTolerance, Double>) -> Binding<Double> {
            Binding(
                get: { session.tolerance(forGroup: index, in: spec)[keyPath: keyPath] },
                set: { newValue in
                    var updated = session.tolerance(forGroup: index, in: spec)
                    updated[keyPath: keyPath] = newValue
                    session.setTolerance(updated, forGroup: index, in: spec)
                })
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ordering tolerance — how close fixtures must be to count as one position when numbering")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button("Reset") {
                    session.setTolerance(session.tolerance, forGroup: index, in: spec)
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(current == session.tolerance)
            }

            toleranceSlider("X", value: binding(\.x))
            toleranceSlider("Y", value: binding(\.y))
            toleranceSlider("Z", value: binding(\.z))
        }
        .padding(14)
    }

    private func toleranceSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)
            Slider(value: value, in: 0.01...1.5)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    // MARK: - Types

    /// Offers to number two lengths of the same product as one system.
    ///
    /// Sits above the type list rather than in a dialog on open: it is a
    /// suggestion about the rows below it, and a modal on the way in would
    /// have to be answered before the user has seen anything to judge it
    /// against.
    @ViewBuilder
    private var familySuggestions: some View {
        let suggestions = session.suggestedTypeMerges
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.self) { specs in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "link")
                                .foregroundStyle(.blue)
                            Text(session.suggestedMergeDescription(specs))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            Button("Number as one") { session.acceptSuggestedMerge(specs) }
                            Button("No thanks") { session.dismissSuggestedMerge(specs) }
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var typeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fixture types — drag to reorder, untick to leave alone")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            familySuggestions

            List(selection: $selectedSpecs) {
                ForEach(session.displayTypes, id: \.self) { spec in
                    typeRow(spec)
                        .tag(spec)
                }
                .onMove { indices, destination in
                    session.moveDisplayTypes(from: indices, to: destination)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { specs in
                typeMenu(for: specs)
            }
        }
        .frame(width: 340)
    }

    /// Shared by the type list's right-click menu and its row button, so
    /// the same actions are reachable without knowing the gesture.
    @ViewBuilder
    private func typeMenu(for specs: Set<String>) -> some View {
                if specs.count == 1, let spec = specs.first {
                    Button("Set starting ID…") {
                        pinText = (session.startingID(forType: spec)
                            ?? session.plan.types.first { $0.spec == spec }?.firstID
                            ?? 1).formatted(.number.grouping(.never))
                        pinTarget = .type(spec)
                    }
                    if session.startingID(forType: spec) != nil {
                        Button("Let it follow on again") {
                            session.setStartingID(nil, forType: spec)
                        }
                    }
                    Divider()
                }
                if specs.count > 1 {
                    Button("Number these types together") {
                        session.merge(types: specs)
                        selectedSpecs = [session.displayTypes.first { specs.contains($0) } ?? ""]
                    }
                }
                if specs.count == 1, let spec = specs.first, session.isMerged(spec) {
                    Button("Number separately again") {
                        session.separate(spec)
                        selectedSpecs = [spec]
                    }
                }

                // Always shown, never enabled: grouping is done to groups,
                // not to a type, and the item says where to go rather than
                // leaving the reader to find out that this menu isn't it.
                Divider()
                Button("Group fixtures together") {}
                    .disabled(true)
                    .help("Select the groups in the middle column, then right-click one of them.")
    }

    private func typeRow(_ spec: String) -> some View {
        let summary = session.plan.types.first { $0.spec == spec }
        let members = session.members(of: spec)
        let included = members.contains { session.includedTypes.contains($0) }

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { included },
                set: { isOn in
                    // A family is in or out as a whole; half a family in the
                    // run would number an instrument's two lengths apart.
                    for member in members {
                        if isOn { session.includedTypes.insert(member) } else { session.includedTypes.remove(member) }
                    }
                }))
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.displayName(for: spec))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(included ? .primary : .secondary)
                    if members.count > 1 {
                        Button {
                            linkedTypesRow = spec
                        } label: {
                            Image(systemName: "link")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Numbered as one type. Click to see which, or to take one out.")
                        .popover(
                            isPresented: Binding(
                                get: { linkedTypesRow == spec },
                                set: { if !$0 { linkedTypesRow = nil } }),
                            arrowEdge: .trailing
                        ) {
                            linkedTypesPanel(members: members)
                        }
                    }
                }

                if let summary {
                    HStack(spacing: 6) {
                        Text("\(summary.fixtureCount) fixtures")
                        Text("·")
                        Text("\(summary.firstID)–\(summary.lastID)")
                            .foregroundStyle(.blue)
                        Text("·")
                        Text("\(summary.groupCount) groups")
                        if session.hasManualGrouping(for: spec) {
                            Image(systemName: "hand.raised.fill")
                                .help("This type's grouping has been adjusted by hand.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("\(session.fixtureCount(of: spec)) fixtures · not renumbered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if session.groupsNeedingAttention(in: spec) > 0, included {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("\(session.groupsNeedingAttention(in: spec)) group(s) here have a shape "
                          + "with no obvious order. Open the type and pick one.")
            }

            Menu {
                typeMenu(for: [spec])
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Starting ID, link with another type…")
        }
        .padding(.vertical, 2)
    }

    /// Replays the flow shortly after things settle.
    ///
    /// Deliberately delayed and cancellable: a recompute fires on every
    /// frame of a tolerance drag, and replaying on each one would strobe the
    /// whole group. Waiting for a pause means one clean playback per change.
    private func scheduleAutoPlay() {
        autoPlayTask?.cancel()
        autoPlayTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            playToken += 1
        }
    }

    // MARK: - Preview

    /// Always on screen rather than opened on demand: checking a grouping
    /// means looking at it, and the whole loop here is pick a type, look,
    /// merge or split, look again.
    private var preview: some View {
        VStack(spacing: 0) {
            // Both stay mounted and are shown by opacity rather than
            // swapped in and out. Rebuilding the 3D view would discard the
            // camera with it, and losing the angle you set up to inspect a
            // group every time you glance at the ID map is the same
            // annoyance that keeps re-framing tied to selection alone.
            GeometryReader { geo in
                ZStack {
                    AutoIDPreviewView(
                        fixtures: session.previewFixtures,
                        focusedSpec: selectedSpec,
                        overlays: previewOverlays,
                        focusedGroup: selectedGroups.count == 1 ? selectedGroups.first : nil,
                        selectedGroups: selectedGroups,
                        revision: session.revision,
                        playToken: playToken,
                        isSplitting: isDrawingSplit,
                        onSplit: { first, second in
                            session.split(into: first, and: second)
                            isDrawingSplit = false
                            selectedGroups = []
                        },
                        onHoverFixture: { fixtureID, point in
                            hoveredFixtureID = fixtureID
                            hoverPoint = point
                        },
                        onPickFixture: { fixtureID, extend in
                            selectGroup(containing: fixtureID, extend: extend)
                        },
                        onRequestMenu: { fixtureID, point in
                            // Right-clicking inside an existing selection
                            // keeps it, so the menu acts on everything
                            // picked rather than throwing the selection
                            // away and acting on one box.
                            if !isSelected(fixtureID) { selectGroup(containing: fixtureID) }
                            menuAnchor = point
                        },
                        onMarqueeGroups: { groups in
                            guard !groups.isEmpty else { return }
                            selectedGroups.formUnion(groups)
                        })
                        .opacity(previewMode == .space ? 1 : 0)
                        .allowsHitTesting(previewMode == .space)

                    // Anchors the group menu where the click landed. A
                    // popover rather than `.contextMenu`, which never fires
                    // for a view that handles its own mouse events.
                    //
                    // Placed with padding inside a top-leading frame, not
                    // `.position`: that modifier moves what is drawn but
                    // leaves the layout frame filling the parent, so the
                    // popover anchored to the whole pane and opened at its
                    // bottom edge instead of at the cursor.
                    if let menuAnchor, previewMode == .space {
                        // The popover attaches to the 1x1 view, *before*
                        // the expanding frame. Attaching it after anchors it
                        // to the full pane — which is the same bug as using
                        // `.position`, reached a different way, and puts the
                        // menu at the bottom of the view instead of at the
                        // cursor.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                            .popover(
                                isPresented: Binding(
                                    get: { self.menuAnchor != nil },
                                    set: { if !$0 { self.menuAnchor = nil } }),
                                // Drops below the cursor the way a menu
                                // does, flipping itself near the bottom.
                                arrowEdge: .top
                            ) {
                                if let spec = selectedSpec {
                                    groupMenuPanel(for: selectedGroups, in: spec)
                                }
                            }
                            .padding(.leading, max(0, min(menuAnchor.x, geo.size.width - 1)))
                            .padding(.top, max(0, min(menuAnchor.y, geo.size.height - 1)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    if previewMode == .space, let fixture = hoveredFixture {
                        hoverCard(for: fixture)
                            // Offset from the cursor and clamped inside the
                            // pane, so the card never covers the fixture it
                            // describes or runs off the edge.
                            .position(
                                x: min(hoverPoint.x + 140, geo.size.width - 120),
                                y: min(hoverPoint.y + 76, geo.size.height - 76))
                            .allowsHitTesting(false)
                    }

                    if previewMode == .idMap {
                        AutoIDMapView(
                            session: session,
                            selectedSpec: selectedSpec,
                            overlays: previewOverlays,
                            // Through `focus`, which knows the group has
                            // to be set after the type change has settled.
                            onSelect: { spec, group in focus(spec: spec, group: group) })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: isDrawingSplit ? "scissors" : previewMode.symbol)
                    .foregroundStyle(isDrawingSplit ? .orange : .secondary)
                Text(previewCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Picker("", selection: $previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if previewMode == .space {
                    Button {
                        playToken += 1
                    } label: {
                        Label(selectedGroups.count == 1 ? "Play group" : "Play order", systemImage: "play.fill")
                    }
                    .disabled(previewOverlays.isEmpty)
                    .help("Flash each fixture in turn, in the order it would be numbered.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
    }

    /// Selects whichever group a clicked fixture belongs to, switching
    /// type if it belongs to another one — clicking a light should take you
    /// to it, not quietly do nothing because a different type is showing.
    /// Whether this fixture's group is already among those selected.
    private func isSelected(_ fixtureID: String) -> Bool {
        guard let assignment = session.plan.assignments.first(where: { $0.fixtureID == fixtureID }),
              assignment.spec == selectedSpec else { return false }
        return selectedGroups.contains(assignment.groupIndex)
    }

    private func selectGroup(containing fixtureID: String, extend: Bool = false) {
        guard let assignment = session.plan.assignments.first(where: { $0.fixtureID == fixtureID }) else { return }

        guard selectedSpec != assignment.spec else {
            if extend {
                // Toggling, so a mis-click can be taken back without
                // starting the selection over.
                if selectedGroups.contains(assignment.groupIndex) {
                    selectedGroups.remove(assignment.groupIndex)
                } else {
                    selectedGroups.insert(assignment.groupIndex)
                }
            } else {
                selectedGroups = [assignment.groupIndex]
            }
            return
        }

        // Changing type clears the group selection — that is what should
        // happen when the *list* changes type, but here it would wipe the
        // group we are switching in order to show. So the group is set
        // after that clear has run, not before it.
        selectedSpecs = [assignment.spec]
        DispatchQueue.main.async {
            selectedGroups = [assignment.groupIndex]
        }
    }

    private var hoveredFixture: MVRFixture? {
        guard let hoveredFixtureID else { return nil }
        return session.previewFixtures.first { $0.id == hoveredFixtureID }
    }

    /// What this fixture is now and what the run would make of it.
    ///
    /// Deliberately not the 3D viewer's card verbatim: there the question
    /// is "what is this fixture", here it is "what happens to it" — so the
    /// proposed ID and the group it landed in lead, with the old ID beside
    /// the new one rather than instead of it.
    private func hoverCard(for fixture: MVRFixture) -> some View {
        let assignment = session.plan.assignments.first { $0.fixtureID == fixture.id }

        return VStack(alignment: .leading, spacing: 3) {
            Text(fixture.name)
                .font(.headline)
                .lineLimit(1)
            Text(session.displayName(ofType: fixture.gdtfSpec))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let assignment {
                Divider().padding(.vertical, 1)

                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(groupColor(assignment.groupIndex) ?? Color.secondary)
                        .frame(width: 8, height: 12)
                    Text(session.name(forGroup: assignment.groupIndex, in: assignment.spec))
                        .font(.caption)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Text("ID").font(.caption).foregroundStyle(.secondary)
                    if let old = assignment.oldID, old != assignment.newID {
                        Text("\(old)").font(.caption.monospacedDigit()).strikethrough()
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("\(assignment.newID)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(assignment.isChanged ? Color.blue : Color.primary)
                }
            } else {
                Divider().padding(.vertical, 1)
                Text("Not in this run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Fixture ID \(fixture.currentFixtureID.map(String.init) ?? "-")")
                    .font(.caption)
            }

            Text("Universe \(fixture.universe) / Channel \(fixture.channel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6)
        .frame(width: 210, alignment: .leading)
    }

    /// Only the type being worked on is drawn, so a rig with 57 groups
    /// doesn't bury the handful actually under review.
    private var previewOverlays: [AutoIDGroupOverlay] {
        guard let selectedSpec, session.includedTypes.contains(selectedSpec) else { return [] }
        return session.groupOverlays(for: selectedSpec)
    }

    private var previewCaption: String {
        if previewMode == .idMap {
            return "Every ID the run would leave behind, gaps included. Click a cell to jump to its group."
        }
        if isDrawingSplit {
            return "Drag a line across the group where it should be cut in two."
        }
        guard let selectedSpec, session.includedTypes.contains(selectedSpec) else {
            return "Select a fixture type to preview its grouping."
        }
        // Each state says what can be done from *here*, rather than one
        // line of everything: the useful sentence when a group is in hand
        // is how to add a second, and when several are how to merge them.
        if selectedGroups.count > 1 {
            return "\(selectedGroups.count) groups selected — right-click to merge them into one. "
                + "Control-click or Control-drag to add more, Control-click a selected box to drop it."
        }
        if selectedGroups.count == 1, let index = selectedGroups.first {
            return session.name(forGroup: index, in: selectedSpec)
                + " — the line runs in ID order from the dot. "
                + "Control-click or Control-drag another box to select several and merge them."
        }
        return "Each box is one group; the line and arrows run in ID order. "
            + "Click one to select it, Control-click or Control-drag to pick several. "
            + "Drag to orbit, Shift-drag to pan."
    }

    @ViewBuilder
    private var groupsPane: some View {
        if let spec = selectedSpec, session.includedTypes.contains(spec) {
            let groups = session.groups(for: spec)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Groups in this type — drag to reorder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if session.hasManualGroupOrder(for: spec) {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("This type's group order has been set by hand.")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                if let note = session.lowestBarNote(for: spec) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }

                // No Merge button: merging is on the group's own right-click
                // menu, where the groups being merged are the ones in hand.
                // A second way in at the top of the column only raised the
                // question of which one to use.
                HStack(spacing: 8) {
                    Spacer()

                    Button("Reset grouping") {
                        session.resetGrouping(for: spec)
                        selectedGroups = []
                    }
                    .disabled(!session.hasManualGrouping(for: spec))
                }
                .padding(12)

                if let range = session.groupingRange(for: spec) {
                    Divider()
                    spacingControls(spec: spec, range: range)
                }

                Divider()

                List(selection: $selectedGroups) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, members in
                        groupRow(index: index, members: members, spec: spec)
                            .tag(index)
                    }
                    .onMove { source, destination in
                        session.moveGroups(from: source, to: destination, in: spec)
                        selectedGroups = []
                    }
                }
                .listStyle(.inset)
                // Per-selection rather than per-row: right-clicking a row
                // that isn't selected acts on that row alone, and
                // right-clicking inside a multiple selection acts on all of
                // it — which is the behaviour flipping wants, since a whole
                // side of a rig usually comes out backwards together.
                .contextMenu(forSelectionType: Int.self) { indices in
                    groupMenu(for: indices, in: spec)
                }
                .popover(
                    isPresented: Binding(
                        get: { spacingTarget != nil },
                        set: { if !$0 { spacingTarget = nil } }),
                    arrowEdge: .trailing
                ) {
                    if let key = spacingTarget {
                        groupSpacingControls(key: key)
                            .frame(width: 300)
                    }
                }
                .popover(isPresented: $showTolerance, arrowEdge: .trailing) {
                    if selectedGroups.count == 1, let index = selectedGroups.first {
                        toleranceControls(index: index, spec: spec)
                            .frame(width: 300)
                    }
                }
                .alert("Set starting ID", isPresented: Binding(
            get: { pinTarget != nil },
            set: { if !$0 { pinTarget = nil } })
        ) {
            TextField("First ID", text: $pinText)
            Button("Set") { applyPin() }
            Button("Cancel", role: .cancel) { pinTarget = nil }
        } message: {
            Text("Numbering starts here. Other types move out of the way; leave it empty to go back to automatic.")
        }
        .alert("That clashes with existing IDs", isPresented: Binding(
            get: { pinClash != nil },
            set: { if !$0 { pinClash = nil } })
        ) {
            Button("Put it back", role: .cancel) {
                if let clash = pinClash { setPin(clash.previous, on: clash.target) }
                pinClash = nil
            }
            Button("Keep it anyway") { pinClash = nil }
        } message: {
            Text("\(pinClash?.count ?? 0) fixtures would share an ID with another. The run can't move those out of the way — they're either pinned too, or kept by a type you've left out.")
        }
            }
        } else {
            ContentUnavailableView(
                selectedSpec == nil ? "Select a fixture type" : "Not being renumbered",
                systemImage: "square.stack.3d.up.slash",
                description: Text(selectedSpec == nil
                                  ? "Pick a type on the left to see the trusses found for it."
                                  : "Tick this type to include it in the run."))
        }
    }

    private func groupRow(index: Int, members: [MVRFixture], spec: String) -> some View {
        let ids = members.compactMap { fixture in
            session.plan.assignments.first { $0.fixtureID == fixture.id }?.newID
        }.sorted()

        return HStack(spacing: 10) {
            // Same colour as this group's box and path in the preview, so a
            // row can be matched to what's on screen at a glance.
            RoundedRectangle(cornerRadius: 3)
                .fill(groupColor(index) ?? Color.secondary)
                .frame(width: 10, height: 26)

            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Suggested from where the group sits and what shape it
                    // is — "Downstage Left Tower" identifies a row in a way
                    // "3" never will.
                    if renamingGroup == index {
                        // Edited in place. A dialog for one short string is
                        // more ceremony than the change deserves.
                        TextField("Name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .focused($renameFieldFocused)
                            .onSubmit { commitRename(index: index, spec: spec) }
                            .onExitCommand { renamingGroup = nil }
                            .onChange(of: renameFieldFocused) { _, focused in
                                // Clicking away keeps what was typed, the
                                // way an editable row does elsewhere.
                                if !focused, renamingGroup == index {
                                    commitRename(index: index, spec: spec)
                                }
                            }
                            .onAppear { renameFieldFocused = true }
                    } else {
                        Text(session.name(forGroup: index, in: spec))
                            // Only the name takes the double-click. Across
                            // the whole row the gesture can swallow a click
                            // meant to select, which reads as the row simply
                            // not responding.
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                selectedGroups = [index]
                                renameText = session.name(forGroup: index, in: spec)
                                renamingGroup = index
                            })
                    }
                    if renamingGroup != index, session.needsAttention(groupIndex: index, in: spec) {
                        // The same mark as on the type row, so following one
                        // to the other doesn't mean re-reading every group.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("This group's shape has no obvious order. Select it to see the route chosen, or pick a different one.")
                    }
                    if renamingGroup != index, session.hasCustomName(forGroup: index, in: spec) {
                        Image(systemName: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Renamed by hand.")
                    }
                    if renamingGroup != index, let first = ids.first, let last = ids.last {
                        Text("·")
                        Text("\(first)–\(last)").foregroundStyle(.blue)
                    }
                }
                Text("\(members.count) fixtures  ·  " + extentDescription(members))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                orderNote(index: index, spec: spec)
            }

            Spacer(minLength: 4)

            // The menu holds rename, order, flip, tolerance, spacing and
            // starting ID. Reachable only by right-click, none of that is
            // discoverable at all — so there is a button for it.
            Menu {
                groupMenu(for: selectedGroups.contains(index) ? selectedGroups : [index], in: spec)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rename, numbering order, flip, grouping distance, starting ID…")
        }
        .padding(.vertical, 2)
        // A type's list skips the bars it isn't on, which looks like a gap
        // in the numbering until you know LX numbers name bars rather than
        // rows. The tooltip is where that gets said.
        .help(session.barNote(forGroup: index, in: spec) ?? "")
        // Simultaneous, so the row's own click-to-select still runs — a
        // plain tap gesture here would swallow it.

    }

    /// Everything you can do to a group. Shared by the list's right-click
    /// menu and the 3D view's, so the two can't drift apart.
    ///
    /// Split and Order live here rather than in the toolbar: both act on
    /// the group you are pointing at, and the pane is too narrow to carry
    /// them as buttons.
    @ViewBuilder
    private func groupMenu(for indices: Set<Int>, in spec: String) -> some View {
        // Shown even for one group, disabled: an action that vanishes
        // teaches nobody it exists, and this is how you find out several
        // groups can be picked at once.
        Button(indices.count > 1 ? "Merge \(indices.count) groups into one" : "Merge into one group") {
            session.merge(groupIndices: indices, in: spec)
            selectedGroups = []
        }
        .disabled(indices.count < 2)
        Divider()

        if !indices.isEmpty {
            Menu {
                let index = indices.min() ?? 0
                // Ticked only when every selected group agrees, so a mixed
                // selection doesn't claim an order it doesn't all have.
                let shared: AutoIDOrderStrategy? = {
                    let all = indices.map { session.ordering(forGroup: $0, in: spec) }
                    return Set(all).count == 1 ? all.first : nil
                }()
                let suggested: AutoIDOrderStrategy? = indices.count == 1
                    ? MVRAutoID.suggestedStrategy(
                        fixtures: session.membership(ofGroup: index, in: spec)?
                            .compactMap { id in session.previewFixtures.first { $0.id == id } } ?? [],
                        tolerance: session.tolerance(forGroup: index, in: spec))
                    : nil

                ForEach(AutoIDOrderStrategy.allCases) { strategy in
                    Button {
                        session.setOrdering(strategy, groupIndices: indices, in: spec)
                    } label: {
                        // The tag marks what the app *would* choose, whether
                        // or not that is what is chosen now — so picking
                        // something else doesn't make the hint disappear.
                        Label(
                            strategy == suggested ? "\(strategy.label)  (suggested)" : strategy.label,
                            systemImage: strategy == shared ? "checkmark" : "")
                    }
                }

                if indices.contains(where: { !session.orderingIsSuggested(forGroup: $0, in: spec) }) {
                    Divider()
                    Button("Use the suggested order") {
                        session.useSuggestedOrdering(groupIndices: indices, in: spec)
                    }
                }
            } label: {
                Label(
                    indices.count > 1 ? "Numbering order of \(indices.count) groups" : "Numbering order",
                    systemImage: "arrow.triangle.turn.up.right.diamond")
            }

            // Directly under the order, because it belongs to it: it sets
            // how close two fixtures must be to be numbered as one
            // position. Sitting further down the menu, between grouping
            // actions, it read as another grouping control.
            if indices.count == 1, let index = indices.first {
                Button {
                    selectedGroups = [index]
                    showTolerance = true
                } label: {
                    Label("Ordering tolerance…", systemImage: "ruler")
                }
            }
            Divider()
        }

        if indices.count == 1, let index = indices.first {
            Button("Grouping distance…") {
                spacingTarget = session.membership(ofGroup: index, in: spec)
            }
            if let key = session.membership(ofGroup: index, in: spec),
               session.groupSpacing(forKey: key) != nil {
                Button("Use the type's grouping distance again") {
                    session.setGroupSpacing(nil, forKey: key)
                }
            }

            Button("Set starting ID…") {
                pinText = (session.startingID(forGroup: index, in: spec)
                    ?? session.plan.assignments.filter { $0.spec == spec && $0.groupIndex == index }
                        .map(\.newID).min() ?? 1).formatted(.number.grouping(.never))
                pinTarget = .group(index: index, spec: spec)
            }
            if session.startingID(forGroup: index, in: spec) != nil {
                Button("Let it follow on again") {
                    session.setStartingID(nil, forGroup: index, in: spec)
                }
            }
            Divider()

            Menu {
                Button("At widest gap") {
                    session.split(groupIndex: index, in: spec)
                    selectedGroups = []
                }
                Button(isDrawingSplit ? "Cancel drawing" : "Draw in 3D…") {
                    selectedGroups = [index]
                    isDrawingSplit.toggle()
                }
            } label: {
                Label("Split", systemImage: "scissors")
            }

            Divider()
        }

        if !indices.isEmpty {
            let reversed = allReversed(indices, in: spec)
            Button(reversed ? "Restore direction" : "Flip direction") {
                session.setReversed(!reversed, groupIndices: indices, in: spec)
            }
        }

        // One at a time: a name describes one position.
        if indices.count == 1, let index = indices.first {
            Divider()
            Button("Rename…") {
                renameText = session.name(forGroup: index, in: spec)
                renamingGroup = index
            }
            if session.hasCustomName(forGroup: index, in: spec) {
                Button("Use suggested name") {
                    session.setName("", forGroup: index, in: spec)
                }
            }
        }
    }

    /// The same actions laid out as a panel, for the places a real context
    /// menu can't be raised.
    private func groupMenuPanel(for indices: Set<Int>, in spec: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            groupMenu(for: indices, in: spec)
        }
        // `.borderless` draws every control in a muted tint, which reads as
        // disabled — the actions worked, they just looked dead. `.plain`
        // with an explicit foreground keeps enabled items looking enabled,
        // and lets a genuinely disabled one stand out.
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .foregroundStyle(.primary)
        .labelStyle(.titleAndIcon)
        .padding(10)
        .frame(width: 220, alignment: .leading)
    }

    /// Applies the typed ID, then checks whether it made things worse.
    private func applyPin() {
        guard let target = pinTarget else { return }
        pinTarget = nil

        let previous: Int?
        switch target {
        case let .type(spec): previous = session.startingID(forType: spec)
        case let .group(index, spec): previous = session.startingID(forGroup: index, in: spec)
        }

        let before = session.plan.collisions.count
        let trimmed = pinText.trimmingCharacters(in: .whitespaces)
        setPin(trimmed.isEmpty ? nil : Int(trimmed), on: target)

        // Only complain about clashes this pin caused. A file that already
        // had them shouldn't have them blamed on the last thing touched.
        let after = session.plan.collisions.count
        if after > before {
            pinClash = (target, previous, after - before)
        }
    }

    private func setPin(_ value: Int?, on target: PinTarget) {
        switch target {
        case let .type(spec): session.setStartingID(value, forType: spec)
        case let .group(index, spec): session.setStartingID(value, forGroup: index, in: spec)
        }
    }

    private func commitRename(index: Int, spec: String) {
        session.setName(renameText, forGroup: index, in: spec)
        renamingGroup = nil
    }

    private func allReversed(_ indices: Set<Int>, in spec: String) -> Bool {
        !indices.isEmpty && indices.allSatisfy { session.isReversed(groupIndex: $0, in: spec) }
    }

    /// The colour the preview draws this group in.
    private func groupColor(_ index: Int) -> Color? {
        let overlays = previewOverlays
        guard overlays.indices.contains(index) else { return nil }
        return Color(nsColor: overlays[index].color)
    }

    /// Says how this group is ordered, and warns when its shape means the
    /// default is only a guess.
    @ViewBuilder
    private func orderNote(index: Int, spec: String) -> some View {
        let strategy = session.ordering(forGroup: index, in: spec)
        let isReversed = session.isReversed(groupIndex: index, in: spec)
        let isAmbiguous = session.isAmbiguous(groupIndex: index, in: spec)
        // Carried into whichever note wins, so a flipped group is never
        // silent just because it also has a custom tolerance.
        let direction = isReversed ? " · reversed" : ""

        if session.hasCustomTolerance(forGroup: index, in: spec) {
            let tolerance = session.tolerance(forGroup: index, in: spec)
            Label(
                String(format: "%@%@ · tolerance %.2f/%.2f/%.2f m",
                       strategy.label, direction, tolerance.x, tolerance.y, tolerance.z),
                systemImage: "ruler.fill")
                .font(.caption)
                .foregroundStyle(.blue)
        } else if strategy != .leftToRight || isReversed {
            Label(
                strategy.label + direction,
                systemImage: isReversed ? "arrow.left.arrow.right" : "arrow.triangle.turn.up.right.diamond.fill")
                .font(.caption)
                .foregroundStyle(.blue)
        } else if isAmbiguous {
            // Clicking the warning opens the menu that fixes it — being
            // told to "pick an order" is no use without being shown where.
            Button {
                selectedGroups = [index]
                warningMenuGroup = index
            } label: {
                Label("Not a straight run — pick an order", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("These fixtures bend away from a straight line, so left-to-right is only a guess. Click to choose an order.")
            .popover(
                isPresented: Binding(
                    get: { warningMenuGroup == index },
                    set: { if !$0 { warningMenuGroup = nil } }),
                arrowEdge: .trailing
            ) {
                groupMenuPanel(for: [index], in: spec)
            }
        }
    }

    /// Size and position of a group, so an obviously-wrong one (a "truss"
    /// 60 metres wide) is visible without opening the 3D view.
    private func extentDescription(_ members: [MVRFixture]) -> String {
        let points = members.compactMap(\.position3D)
        guard !points.isEmpty else { return "no position" }
        let xs = points.map { $0.x / 1000 }, ys = points.map { $0.y / 1000 }, zs = points.map { $0.z / 1000 }
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let depth = (ys.max() ?? 0) - (ys.min() ?? 0)
        let height = (zs.max() ?? 0) - (zs.min() ?? 0)
        let centreY = ys.reduce(0, +) / Double(ys.count)
        return String(format: "%.1f × %.1f × %.1f m  ·  depth %.1f m", width, depth, height, centreY)
    }

    private var changesPane: some View {
        Table(session.plan.assignments.filter(\.isChanged)) {
            TableColumn("Fixture") { Text($0.name) }
            TableColumn("Type") { Text($0.spec).lineLimit(1).truncationMode(.middle) }
            TableColumn("Old") { Text($0.oldID.map(String.init) ?? "-") }
            TableColumn("New") { Text("\($0.newID)").foregroundStyle(.blue) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if !session.plan.collisions.isEmpty {
                Label(
                    "\(session.plan.collisions.count) IDs clash with types you've excluded",
                    systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Excluded types keep their existing IDs. Move the starting ID clear of them, or include those types too.")
            }

            Spacer()

            Button {
                showChanges = true
            } label: {
                Label("\(session.plan.changedCount) changes…", systemImage: "list.bullet.rectangle")
            }
            .disabled(session.plan.changedCount == 0)
            .popover(isPresented: $showChanges, arrowEdge: .top) {
                changesPane
                    .frame(width: 620, height: 420)
            }

            Button("Cancel") { requestCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { onApply() }
                .keyboardShortcut(.defaultAction)
                .disabled(session.plan.changedCount == 0)
        }
        .padding(12)
    }
}
