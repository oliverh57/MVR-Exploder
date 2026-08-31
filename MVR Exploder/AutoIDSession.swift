import Foundation
import Combine
import AppKit
import SwiftUI   // IndexSet.move(fromOffsets:toOffset:)

/// Live state behind the Auto Fixture ID sheet: the options being tuned, the
/// plan they currently produce, and the manual corrections layered on top.
///
/// The plan is recomputed from scratch on every change rather than patched
/// incrementally. It's cheap enough at real rig sizes, and it means the
/// preview can never drift from what Apply would actually do.
@MainActor
final class AutoIDSession: ObservableObject, Identifiable {
    /// Presenting the sheet by item keeps the session and the sheet's
    /// lifetime together, so a run always starts from the current fixtures.
    nonisolated let id = UUID()

    @Published private(set) var plan: AutoIDPlan
    @Published private(set) var typeCounts: [String: Int]
    /// Bumped on every recompute, so the 3D preview can tell a real change
    /// from the many SwiftUI updates that don't affect the grouping.
    @Published private(set) var revision = 0

    /// True while undo/redo is writing state back, which must not itself
    /// record steps or recompute once per property.
    private var isRestoring = false

    // `willSet`, not `didSet`: a checkpoint has to capture the state
    // *before* the change or undo restores what it was just given.
    @Published var startingID: Int {
        willSet { checkpoint("Starting ID", coalescing: true) }
        didSet { if !isRestoring { recompute() } }
    }
    /// Spare IDs left between groups and between fixtures.
    @Published var gaps: AutoIDGaps {
        willSet { checkpoint("ID gaps", coalescing: true) }
        didSet { if !isRestoring { recompute() } }
    }
    /// Every type in the file, in the order blocks are allocated.
    @Published var typeOrder: [String] { didSet { if !isRestoring { recompute() } } }
    @Published var includedTypes: Set<String> {
        willSet { checkpoint("Include types") }
        didSet { if !isRestoring { recompute() } }
    }
    /// Fallback slop for groups that haven't been given their own.
    @Published var tolerance: AutoIDTolerance {
        willSet { checkpoint("Tolerance", coalescing: true) }
        didSet { if !isRestoring { recompute() } }
    }

    /// The fixtures this run covers, for the 3D preview to draw.
    var previewFixtures: [MVRFixture] { fixtures }

    private var manualGroups: [Set<String>] = []
    private var groupOrdering: [Set<String>: AutoIDOrderStrategy] = [:]
    private var groupTolerance: [Set<String>: AutoIDTolerance] = [:]
    private var groupReversed: Set<Set<String>> = []
    private var groupNames: [Set<String>: String] = [:]
    /// Fixture types the user has told the tool to number as one.
    @Published private(set) var mergedTypes: [Set<String>] = []
    private var typeStartingID: [String: Int] = [:]
    private var groupStartingID: [Set<String>: Int] = [:]
    private var groupSpacing: [Set<String>: Double] = [:]
    private var groupOrder: [String: [Set<String>]] = [:]
    private var customGroupingDistance: [String: Double] = [:]
    /// Family suggestions the user has said no to.
    private var dismissedMerges: Set<Set<String>> = []

    // MARK: - Undo

    /// Everything the user can change, captured whole.
    ///
    /// Snapshotting the state rather than modelling each operation: the
    /// corrections here are a dozen loosely-related dictionaries, and an
    /// undo built per-operation would need a matching inverse for each one
    /// and would rot the next time one is added. A snapshot cannot get out
    /// of step with what it restores.
    private struct Snapshot {
        var startingID: Int
        var gaps: AutoIDGaps
        var typeOrder: [String]
        var includedTypes: Set<String>
        var tolerance: AutoIDTolerance
        var manualGroups: [Set<String>]
        var groupOrdering: [Set<String>: AutoIDOrderStrategy]
        var groupTolerance: [Set<String>: AutoIDTolerance]
        var groupReversed: Set<Set<String>>
        var groupNames: [Set<String>: String]
        var mergedTypes: [Set<String>]
        var typeStartingID: [String: Int]
        var groupStartingID: [Set<String>: Int]
        var groupSpacing: [Set<String>: Double]
        var groupOrder: [String: [Set<String>]]
        var customGroupingDistance: [String: Double]
        var dismissedMerges: Set<Set<String>>
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// What the last checkpoint was for, and when, so a slider drag becomes
    /// one undo step instead of two hundred.
    private var lastCheckpoint: (label: String, at: Date)?

    private var maximumUndoSteps: Int { 50 }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// True when this sitting has changed something that closing the tool
    /// would throw away.
    ///
    /// Read off the undo stack, which every mutating operation feeds. A
    /// session restored from the file doesn't count on its own — that
    /// state is in the file either way, and `adopt` records no checkpoint.
    var hasUnsavedWork: Bool { canUndo || canRedo }

    private func snapshot() -> Snapshot {
        Snapshot(
            startingID: startingID, gaps: gaps, typeOrder: typeOrder,
            includedTypes: includedTypes, tolerance: tolerance, manualGroups: manualGroups,
            groupOrdering: groupOrdering, groupTolerance: groupTolerance,
            groupReversed: groupReversed, groupNames: groupNames, mergedTypes: mergedTypes,
            typeStartingID: typeStartingID, groupStartingID: groupStartingID,
            groupSpacing: groupSpacing, groupOrder: groupOrder,
            customGroupingDistance: customGroupingDistance,
            dismissedMerges: dismissedMerges)
    }

    private func restore(_ snapshot: Snapshot) {
        isRestoring = true
        startingID = snapshot.startingID
        gaps = snapshot.gaps
        typeOrder = snapshot.typeOrder
        includedTypes = snapshot.includedTypes
        tolerance = snapshot.tolerance
        manualGroups = snapshot.manualGroups
        groupOrdering = snapshot.groupOrdering
        groupTolerance = snapshot.groupTolerance
        groupReversed = snapshot.groupReversed
        groupNames = snapshot.groupNames
        mergedTypes = snapshot.mergedTypes
        typeStartingID = snapshot.typeStartingID
        groupStartingID = snapshot.groupStartingID
        groupSpacing = snapshot.groupSpacing
        groupOrder = snapshot.groupOrder
        customGroupingDistance = snapshot.customGroupingDistance
        dismissedMerges = snapshot.dismissedMerges
        isRestoring = false
        recompute()
    }

    /// Records a step before a change.
    ///
    /// `coalescing` merges consecutive changes of the same kind made in
    /// quick succession, so dragging a slider — which recomputes on every
    /// frame — is one thing to undo rather than hundreds.
    func checkpoint(_ label: String, coalescing: Bool = false) {
        guard !isRestoring else { return }

        if coalescing, let last = lastCheckpoint,
           last.label == label, Date().timeIntervalSince(last.at) < 1.2 {
            lastCheckpoint = (label, Date())
            return
        }

        undoStack.append(snapshot())
        if undoStack.count > maximumUndoSteps { undoStack.removeFirst() }
        redoStack.removeAll()
        lastCheckpoint = (label, Date())
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        lastCheckpoint = nil
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        lastCheckpoint = nil
        restore(next)
    }
    /// Computed once per type: the automatic grouping distance and the two
    /// ends of the range worth offering. Fixed for the life of the session
    /// because they depend only on where the fixtures are, so the slider
    /// can't shift underfoot as groups are merged and split.
    private let groupingBounds: [String: (auto: Double, minimum: Double, maximum: Double)]
    private let fixtures: [MVRFixture]
    private let fixturesByID: [String: MVRFixture]
    /// Names an earlier run left in the file, per fixture.
    private let storedNames: [String: String]
    /// Human-readable name per GDTF spec, distinct within this document.
    private let typeDisplayNames: [String: String]

    /// The order types fall into with nothing set, kept so a session can
    /// be told apart from an untouched run — only a changed one is worth
    /// writing into the file.
    private let defaultTypeOrder: [String]
    /// True once a restored session has been thrown away, so it isn't
    /// silently written back on the next export.
    @Published private(set) var restoredFromFile = false

    init(
        fixtures: [MVRFixture],
        storedNames: [String: String] = [:],
        session: AutoIDStoredSession? = nil
    ) {
        self.fixtures = fixtures
        self.storedNames = storedNames
        self.fixturesByID = Dictionary(fixtures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var counts: [String: Int] = [:]
        var bySpec: [String: [MVRFixture]] = [:]
        for fixture in fixtures {
            counts[fixture.gdtfSpec, default: 0] += 1
            bySpec[fixture.gdtfSpec, default: []].append(fixture)
        }
        self.typeCounts = counts
        self.typeDisplayNames = GDTFSpecName.readableNames(for: Array(counts.keys))
        self.groupingBounds = bySpec.compactMapValues { MVRAutoID.groupingBounds(fixtures: $0) }

        // Biggest systems first by default, so the workhorse type gets the
        // lowest block. Reorderable by drag.
        let order = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        self.defaultTypeOrder = order
        self.typeOrder = order
        self.includedTypes = Set(order)
        self.startingID = AutoIDOptions.defaultStartingID
        self.gaps = AutoIDGaps()
        self.tolerance = .default
        self.plan = AutoIDPlan(assignments: [], types: [], groupsBySpec: [:], lxNumbersBySpec: [:], groupNamesBySpec: [:], collisions: [])

        if let session { adopt(session) }
        recompute()
    }

    // MARK: - Saved sessions

    /// Everything the user has corrected, ready to be written into the
    /// file. Fixture keys are this load's ids; the exporter maps them onto
    /// MVR uuids on the way out.
    var storedSession: AutoIDStoredSession {
        var stored = AutoIDStoredSession()
        stored.startingID = startingID
        stored.gaps = gaps
        stored.tolerance = tolerance
        stored.typeOrder = typeOrder
        stored.includedTypes = includedTypes.sorted()
        stored.typeStartingID = typeStartingID
        stored.customGroupingDistance = customGroupingDistance
        // Specs, not fixtures — deliberately outside the key remapping.
        stored.mergedTypes = AutoIDStoredSession.sortedGroups(mergedTypes)
        stored.dismissedMerges = AutoIDStoredSession.sortedGroups(Array(dismissedMerges))
        stored.manualGroups = AutoIDStoredSession.sortedGroups(manualGroups)
        stored.groupReversed = AutoIDStoredSession.sortedGroups(Array(groupReversed))
        stored.acknowledged = AutoIDStoredSession.sortedGroups(Array(acknowledged))
        stored.groupOrdering = AutoIDStoredSession.entries(from: groupOrdering.mapValues(\.rawValue))
        stored.groupNames = AutoIDStoredSession.entries(from: groupNames)
        stored.groupTolerance = AutoIDStoredSession.entries(from: groupTolerance)
        stored.groupStartingID = AutoIDStoredSession.entries(from: groupStartingID)
        stored.groupSpacing = AutoIDStoredSession.entries(from: groupSpacing)
        // Members sorted, the list itself left alone: this one *is* the
        // order the user dragged the groups into.
        stored.groupOrder = groupOrder.mapValues { $0.map { $0.sorted() } }
        return stored
    }

    /// True when anything differs from what a fresh run over this file
    /// would produce. A file the user only looked at gets no block written.
    var hasCorrections: Bool {
        startingID != AutoIDOptions.defaultStartingID
            || gaps != AutoIDGaps()
            || tolerance != .default
            || typeOrder != defaultTypeOrder
            || includedTypes != Set(defaultTypeOrder)
            || !typeStartingID.isEmpty
            || !customGroupingDistance.isEmpty
            || !mergedTypes.isEmpty
            || !dismissedMerges.isEmpty
            || !manualGroups.isEmpty
            || !groupReversed.isEmpty
            || !groupOrdering.isEmpty
            || !groupNames.isEmpty
            || !groupTolerance.isEmpty
            || !groupStartingID.isEmpty
            || !groupSpacing.isEmpty
            || !groupOrder.isEmpty
    }

    /// Takes on a session read back from the file.
    ///
    /// Only what still applies: a spec that isn't in this file is dropped,
    /// and if none of them are — the block came from a different show —
    /// the session is ignored outright rather than leaving the tool with
    /// no types included and nothing to number.
    private func adopt(_ stored: AutoIDStoredSession) {
        let present = Set(defaultTypeOrder)
        let order = stored.typeOrder.filter(present.contains)
        guard !order.isEmpty else { return }

        isRestoring = true
        defer { isRestoring = false }

        typeOrder = order + defaultTypeOrder.filter { !order.contains($0) }
        includedTypes = Set(stored.includedTypes).intersection(present)
        startingID = stored.startingID
        gaps = stored.gaps
        tolerance = stored.tolerance

        typeStartingID = stored.typeStartingID.filter { present.contains($0.key) }
        customGroupingDistance = stored.customGroupingDistance.filter { present.contains($0.key) }
        mergedTypes = stored.mergedTypes
            .map { Set($0.filter(present.contains)) }
            .filter { $0.count > 1 }
        dismissedMerges = Set(stored.dismissedMerges
            .map { Set($0.filter(present.contains)) }
            .filter { $0.count > 1 })

        manualGroups = stored.manualGroups.map(Set.init)
        groupReversed = Set(stored.groupReversed.map(Set.init))
        acknowledged = Set(stored.acknowledged.map(Set.init))
        groupNames = AutoIDStoredSession.dictionary(from: stored.groupNames)
        groupTolerance = AutoIDStoredSession.dictionary(from: stored.groupTolerance)
        groupStartingID = AutoIDStoredSession.dictionary(from: stored.groupStartingID)
        groupSpacing = AutoIDStoredSession.dictionary(from: stored.groupSpacing)
        groupOrdering = AutoIDStoredSession.dictionary(from: stored.groupOrdering)
            .compactMapValues(AutoIDOrderStrategy.init(rawValue:))
        groupOrder = stored.groupOrder
            .filter { present.contains($0.key) }
            .mapValues { $0.map(Set.init) }

        restoredFromFile = true
    }

    /// Throws away everything and starts the run again from scratch.
    func startFresh() {
        checkpoint("Start fresh")
        isRestoring = true
        typeOrder = defaultTypeOrder
        includedTypes = Set(defaultTypeOrder)
        startingID = AutoIDOptions.defaultStartingID
        gaps = AutoIDGaps()
        tolerance = .default
        typeStartingID = [:]
        customGroupingDistance = [:]
        mergedTypes = []
        dismissedMerges = []
        manualGroups = []
        groupReversed = []
        acknowledged = []
        groupNames = [:]
        groupTolerance = [:]
        groupStartingID = [:]
        groupSpacing = [:]
        groupOrdering = [:]
        groupOrder = [:]
        isRestoring = false
        restoredFromFile = false
        recompute()
    }

    var options: AutoIDOptions {
        var options = AutoIDOptions()
        options.startingID = startingID
        options.gaps = gaps
        options.typeOrder = typeOrder
        options.includedTypes = includedTypes
        options.manualGroups = manualGroups
        options.groupOrdering = groupOrdering
        options.tolerance = tolerance
        options.groupTolerance = groupTolerance
        options.groupReversed = groupReversed
        options.groupNames = groupNames
        options.storedNames = storedNames
        options.mergedTypes = mergedTypes
        options.typeStartingID = typeStartingID
        options.groupStartingID = groupStartingID
        options.groupSpacing = groupSpacing
        options.groupOrder = groupOrder
        options.groupingDistance = customGroupingDistance
        return options
    }

    private var strategyCache: [Set<String>: AutoIDOrderStrategy] = [:]
    /// Groups the user has looked at, keyed by membership.
    private var acknowledged: Set<Set<String>> = []

    func recompute() {
        strategyCache.removeAll(keepingCapacity: true)
        plan = MVRAutoID.plan(fixtures: fixtures, options: options)
        revision += 1
    }

    // MARK: - Manual corrections

    /// The suggested name for one group, or a plain number if naming
    /// produced nothing for it.
    func name(forGroup index: Int, in spec: String) -> String {
        let names = plan.groupNamesBySpec[spec] ?? []
        return names.indices.contains(index) ? names[index] : "Group \(index + 1)"
    }

    /// Renames one group. An empty name puts the suggestion back.
    func setName(_ name: String, forGroup index: Int, in spec: String) {
        checkpoint("Rename group")
        guard let ids = groupIDs(index, in: spec) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            groupNames.removeValue(forKey: ids)
        } else {
            groupNames[ids] = trimmed
        }
        recompute()
    }

    func hasCustomName(forGroup index: Int, in spec: String) -> Bool {
        guard let ids = groupIDs(index, in: spec) else { return false }
        return groupNames[ids] != nil
    }

    /// Explains a group's place in the rig's LX numbering — including why
    /// a type's own list skips numbers, which is the first thing that looks
    /// wrong about it: LX numbers name *bars*, and a type only appears on
    /// the bars it actually hangs on.
    // MARK: - Suggested families

    /// Types that look like one system in two lengths, and haven't been
    /// linked or waved away yet.
    ///
    /// A Sceptron 320 and a Sceptron 100 are one product on one bar, and a
    /// rig treats them as one run of pixels — but they arrive as two GDTF
    /// types and get two blocks of IDs interleaved down the truss unless
    /// someone says otherwise. The tool can see the pairing from the names,
    /// so it offers it rather than waiting to be told.
    ///
    /// Offered, never applied: linking changes how a whole type is
    /// numbered, and the names are evidence, not proof.
    var suggestedTypeMerges: [[String]] {
        var byFamily: [String: [String]] = [:]
        for spec in displayTypes where !isMerged(spec) {
            guard let family = GDTFSpecName.family(of: displayName(for: spec)) else { continue }
            byFamily[family, default: []].append(spec)
        }

        return byFamily.values
            .filter { $0.count > 1 && !dismissedMerges.contains(Set($0)) }
            // Biggest first, and stable: `Dictionary.values` has no order
            // of its own and a suggestion banner that reshuffles itself
            // between recomputes is worse than no banner.
            .map { $0.sorted { (fixtureCount(of: $0), $1) > (fixtureCount(of: $1), $0) } }
            .sorted { first, second in
                let counts = (first.reduce(0) { $0 + fixtureCount(of: $1) },
                              second.reduce(0) { $0 + fixtureCount(of: $1) })
                return counts.0 == counts.1 ? first[0] < second[0] : counts.0 > counts.1
            }
    }

    /// The suggestion in words, naming the types and what they'd become.
    func suggestedMergeDescription(_ specs: [String]) -> String {
        let names = specs.map { displayName(for: $0) }
        let total = specs.reduce(0) { $0 + fixtureCount(of: $1) }
        let listed = names.count == 2
            ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        return "\(listed) look like one system in different lengths. "
            + "Number them as one type, so all \(total) run in a single sequence?"
    }

    /// Takes up a suggestion — the same operation as linking by hand.
    func acceptSuggestedMerge(_ specs: [String]) {
        merge(types: Set(specs))
    }

    /// Turns one down. Remembered, and saved with the session, so a file
    /// re-opened next week doesn't ask again.
    func dismissSuggestedMerge(_ specs: [String]) {
        checkpoint("Dismiss suggestion")
        dismissedMerges.insert(Set(specs))
        recompute()
    }

    /// Why this type's bars don't start at LX1, in one line.
    ///
    /// Bars are numbered across the whole rig, not per type, so a type
    /// that isn't on the downstage bar starts partway up the count. That is
    /// correct and looks like a fault — "why does this start at LX2?" — so
    /// the answer is given where the numbers are, rather than left in a
    /// tooltip on one row.
    func lowestBarNote(for spec: String) -> String? {
        let mine = (plan.lxNumbersBySpec[spec] ?? []).compactMap { $0 }
        guard let lowest = mine.min(), lowest > 1 else { return nil }

        // Which types carry the bars below this one.
        var carriers: [(number: Int, type: String)] = []
        for (candidate, numbers) in plan.lxNumbersBySpec where candidate != spec {
            for number in numbers.compactMap({ $0 }) where number < lowest {
                carriers.append((number, displayName(for: candidate)))
            }
        }
        let names = orderedUniqueNames(carriers.sorted { $0.number < $1.number }.map(\.type))
        guard !names.isEmpty else { return nil }

        let bars = lowest == 2 ? "LX1" : "LX1–LX\(lowest - 1)"
        // Two named, then a count. Three names ran the note to three lines
        // in the pane, which is more room than "so where is LX1?" is worth.
        let on: String
        switch names.count {
        case 1: on = names[0]
        case 2: on = names.joined(separator: " and ")
        default: on = names.prefix(2).joined(separator: ", ")
            + " and \(names.count - 2) other\(names.count == 3 ? "" : "s")"
        }
        // The subject is the bars, not the types: one bar below is "LX1
        // is", several is "LX1–LX3 are".
        return "Bars are numbered across the whole rig. \(bars) "
            + "\(lowest == 2 ? "is" : "are") on \(on), so this type starts at LX\(lowest)."
    }

    private func orderedUniqueNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    func barNote(forGroup index: Int, in spec: String) -> String? {
        guard let number = (plan.lxNumbersBySpec[spec] ?? [])[safeIndex: index] ?? nil else { return nil }

        var total: Set<Int> = []
        var sharedWith: Set<String> = []
        for (candidate, numbers) in plan.lxNumbersBySpec {
            for value in numbers.compactMap({ $0 }) {
                total.insert(value)
                if value == number, candidate != spec { sharedWith.insert(candidate) }
            }
        }

        var note = "LX\(number) of \(total.count) bars in the rig. Bars are numbered across the whole rig, so this type's list skips the ones it isn't on."
        if !sharedWith.isEmpty {
            note += "\nAlso on this bar: " + sharedWith.sorted().joined(separator: ", ") + "."
        }
        return note
    }

    /// What to call a fixture type on screen.
    func displayName(ofType spec: String) -> String {
        typeDisplayNames[spec] ?? spec
    }

    func groups(for spec: String) -> [[MVRFixture]] {
        (plan.groupsBySpec[spec] ?? []).map { ids in ids.compactMap { fixturesByID[$0] } }
    }

    /// Fuses the given groups of one type into a single truss.
    func merge(groupIndices: Set<Int>, in spec: String) {
        checkpoint("Merge groups")
        let groups = plan.groupsBySpec[spec] ?? []
        let ids = Set(groupIndices.compactMap { groups.indices.contains($0) ? groups[$0] : nil }.flatMap { $0 })
        guard ids.count > 1 else { return }

        // Drop any hand-made groups swallowed by this one, so the same
        // fixtures can't be claimed twice.
        manualGroups.removeAll { $0.isSubset(of: ids) }
        manualGroups.append(ids)
        recompute()
    }

    /// Cuts one group in two at its widest gap.
    func split(groupIndex: Int, in spec: String) {
        checkpoint("Split group")
        let groups = plan.groupsBySpec[spec] ?? []
        guard groups.indices.contains(groupIndex) else { return }
        let ids = Set(groups[groupIndex])
        let members = ids.compactMap { fixturesByID[$0] }
        guard let (first, second) = MVRAutoID.splitAtLargestGap(fixtures: members) else { return }

        manualGroups.removeAll { $0 == ids }
        manualGroups.append(first)
        manualGroups.append(second)
        recompute()
    }

    /// How this group's numbers run. Defaults to left-to-right, which is
    /// right for a straight truss and a guess for anything else.
    func ordering(forGroup index: Int, in spec: String) -> AutoIDOrderStrategy {
        guard let ids = groupIDs(index, in: spec) else { return .leftToRight }
        if let chosen = groupOrdering[ids] { return chosen }

        // Cached per recompute: working out the suggestion means ordering
        // the group five ways, and every visible row asks for it.
        if let cached = strategyCache[ids] { return cached }
        let suggested = MVRAutoID.suggestedStrategy(
            fixtures: ids.compactMap { fixturesByID[$0] },
            tolerance: groupTolerance[ids] ?? tolerance)
        strategyCache[ids] = suggested
        return suggested
    }

    /// True when the strategy in force was chosen by the app, not the user.
    func orderingIsSuggested(forGroup index: Int, in spec: String) -> Bool {
        guard let ids = groupIDs(index, in: spec) else { return false }
        return groupOrdering[ids] == nil
    }

    /// Sets the order for several groups at once.
    ///
    /// Memberships are resolved *before* anything is written, because the
    /// first write recomputes the plan and the remaining indices would then
    /// point at different groups. Also one undo step, not one per group.
    func setOrdering(_ strategy: AutoIDOrderStrategy, groupIndices: Set<Int>, in spec: String) {
        let keys = groupIndices.compactMap { groupIDs($0, in: spec) }
        guard !keys.isEmpty else { return }
        checkpoint(keys.count > 1 ? "Change order of \(keys.count) groups" : "Change order")

        // Always recorded, never inferred from being the old default.
        //
        // This used to clear the entry for `.leftToRight`, back when that
        // *was* the fallback. Now the fallback is the suggested strategy,
        // so clearing it meant picking left-to-right on a group suggested
        // "around the shape" silently re-chose around the shape — the one
        // order that could not be selected.
        for ids in keys { groupOrdering[ids] = strategy }
        recompute()
    }

    func setOrdering(_ strategy: AutoIDOrderStrategy, forGroup index: Int, in spec: String) {
        setOrdering(strategy, groupIndices: [index], in: spec)
    }

    /// Hands the groups back to the app's own choice.
    func useSuggestedOrdering(groupIndices: Set<Int>, in spec: String) {
        let keys = groupIndices.compactMap { groupIDs($0, in: spec) }
        guard keys.contains(where: { groupOrdering[$0] != nil }) else { return }
        checkpoint("Use suggested order")
        for ids in keys { groupOrdering.removeValue(forKey: ids) }
        recompute()
    }

    /// Reorders a type's groups by hand, which reorders the ID blocks with
    /// them — the automatic downstage-to-upstage run is a decent guess but
    /// not always the order a rig is thought about in.
    func moveGroups(from source: IndexSet, to destination: Int, in spec: String) {
        checkpoint("Reorder groups")
        var keys = (plan.groupsBySpec[spec] ?? []).map { Set($0) }
        keys.move(fromOffsets: source, toOffset: destination)
        groupOrder[spec] = keys
        recompute()
    }

    func hasManualGroupOrder(for spec: String) -> Bool {
        groupOrder[spec] != nil
    }

    /// Splits a group into two halves the user has drawn in the preview.
    ///
    /// Unlike the widest-gap cut, this puts the boundary exactly where it
    /// was drawn — which is what a truss of two staggered rows needs, since
    /// its biggest gap runs along the rows rather than between them.
    func split(into first: Set<String>, and second: Set<String>) {
        checkpoint("Split group")
        guard !first.isEmpty, !second.isEmpty else { return }
        let whole = first.union(second)
        manualGroups.removeAll { $0.isSubset(of: whole) }
        manualGroups.append(first)
        manualGroups.append(second)
        recompute()
    }

    // MARK: - Per-group spacing

    /// The membership of one group, which is how a per-group setting is
    /// addressed. Held by the UI while a slider is open, since re-splitting
    /// the group changes which rows exist underneath it.
    func membership(ofGroup index: Int, in spec: String) -> Set<String>? {
        groupIDs(index, in: spec)
    }

    func groupSpacing(forKey ids: Set<String>) -> Double? { groupSpacing[ids] }

    func setGroupSpacing(_ value: Double?, forKey ids: Set<String>) {
        checkpoint("Group spacing", coalescing: true)
        if let value { groupSpacing[ids] = value } else { groupSpacing.removeValue(forKey: ids) }
        recompute()
    }

    /// The span worth offering for one blob, from its own fixtures.
    func groupSpacingRange(forKey ids: Set<String>) -> ClosedRange<Double>? {
        let members = ids.compactMap { fixturesByID[$0] }
        guard let bounds = MVRAutoID.groupingBounds(fixtures: members),
              bounds.maximum > bounds.minimum * 1.01 else { return nil }
        return bounds.minimum...bounds.maximum
    }

    func automaticGroupSpacing(forKey ids: Set<String>) -> Double {
        let members = ids.compactMap { fixturesByID[$0] }
        return MVRAutoID.groupingBounds(fixtures: members)?.auto ?? 1
    }

    // MARK: - Pinned starting IDs

    func startingID(forType spec: String) -> Int? { typeStartingID[spec] }

    /// Pins where a type's block begins. Everything not pinned flows
    /// around it. Passing nil hands the type back to automatic allocation.
    func setStartingID(_ value: Int?, forType spec: String) {
        checkpoint("Set starting ID")
        if let value { typeStartingID[spec] = max(1, value) } else { typeStartingID.removeValue(forKey: spec) }
        recompute()
    }

    func startingID(forGroup index: Int, in spec: String) -> Int? {
        guard let ids = groupIDs(index, in: spec) else { return nil }
        return groupStartingID[ids]
    }

    func setStartingID(_ value: Int?, forGroup index: Int, in spec: String) {
        checkpoint("Set starting ID")
        guard let ids = groupIDs(index, in: spec) else { return }
        if let value { groupStartingID[ids] = max(1, value) } else { groupStartingID.removeValue(forKey: ids) }
        recompute()
    }

    // MARK: - Merged types

    /// The types shown as rows: one per family, in the user's order.
    var displayTypes: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for spec in typeOrder {
            let key = family(of: spec)
            if seen.insert(key).inserted { result.append(key) }
        }
        return result
    }

    /// Every spec numbered under this one, in the user's order.
    func members(of spec: String) -> [String] {
        guard let set = mergedTypes.first(where: { $0.contains(spec) }), set.count > 1 else { return [spec] }
        return typeOrder.filter { set.contains($0) }
    }

    func isMerged(_ spec: String) -> Bool { members(of: spec).count > 1 }

    /// Fixtures across a whole family, for the row's count.
    func fixtureCount(of spec: String) -> Int {
        members(of: spec).reduce(0) { $0 + (typeCounts[$1] ?? 0) }
    }

    /// What the row calls a family: the first member, plus how many others.
    func displayName(for spec: String) -> String {
        let all = members(of: spec)
        guard all.count > 1 else { return displayName(ofType: spec) }
        return "\(displayName(ofType: all[0]))  + \(all.count - 1) more"
    }

    /// Numbers the given types as one — same block, one sequence.
    ///
    /// Existing families that overlap the selection are absorbed, so
    /// merging A+B and then B+C gives one family of three rather than two
    /// families disagreeing about B.
    func merge(types: Set<String>) {
        checkpoint("Link types")
        let absorbed = mergedTypes.filter { !$0.isDisjoint(with: types) }
        var combined = types
        for family in absorbed { combined.formUnion(family) }
        guard combined.count > 1 else { return }

        mergedTypes.removeAll { !$0.isDisjoint(with: combined) }
        mergedTypes.append(combined)

        // A merged family must sit together in the order, or its members
        // would claim blocks either side of an unrelated type.
        let ordered = typeOrder.filter { combined.contains($0) }
        guard let anchor = typeOrder.firstIndex(where: { combined.contains($0) }) else { return }
        var rest = typeOrder.filter { !combined.contains($0) }
        rest.insert(contentsOf: ordered, at: min(anchor, rest.count))
        if rest == typeOrder { recompute() } else { typeOrder = rest }
    }

    /// Splits a family back into its own types.
    func separate(_ spec: String) {
        checkpoint("Unlink types")
        mergedTypes.removeAll { $0.contains(spec) }
        recompute()
    }

    /// Takes one type out of its family, leaving the others linked.
    ///
    /// A family of one is no family, so the last pair separates entirely
    /// rather than leaving a lone type marked as linked to nothing.
    func unlink(_ spec: String) {
        checkpoint("Unlink type")
        guard let index = mergedTypes.firstIndex(where: { $0.contains(spec) }) else { return }
        var family = mergedTypes[index]
        family.remove(spec)
        if family.count > 1 {
            mergedTypes[index] = family
        } else {
            mergedTypes.remove(at: index)
        }
        recompute()
    }

    /// Reorders the visible rows, carrying each family's members with it.
    func moveDisplayTypes(from source: IndexSet, to destination: Int) {
        checkpoint("Reorder types")
        var rows = displayTypes
        rows.move(fromOffsets: source, toOffset: destination)
        typeOrder = rows.flatMap { members(of: $0) }
    }

    private func family(of spec: String) -> String {
        members(of: spec).first ?? spec
    }

    // MARK: - Grouping distance

    /// How far apart fixtures of this type can sit and still group together.
    ///
    /// Separate from `AutoIDTolerance`, which decides whether two fixtures
    /// share a position when ordering *within* a group. This one decides
    /// where one group ends and the next begins.
    func groupingDistance(for spec: String) -> Double {
        customGroupingDistance[spec] ?? groupingBounds[spec]?.auto ?? 1
    }

    /// The span worth offering on a slider, or nil for a type with too few
    /// positioned fixtures to group at all.
    func groupingRange(for spec: String) -> ClosedRange<Double>? {
        guard let bounds = groupingBounds[spec], bounds.maximum > bounds.minimum * 1.01 else { return nil }
        return bounds.minimum...bounds.maximum
    }

    func setGroupingDistance(_ value: Double, for spec: String) {
        checkpoint("Type spacing", coalescing: true)
        customGroupingDistance[spec] = value
        recompute()
    }

    func resetGroupingDistance(for spec: String) {
        checkpoint("Type spacing")
        guard customGroupingDistance.removeValue(forKey: spec) != nil else { return }
        recompute()
    }

    func hasCustomGroupingDistance(for spec: String) -> Bool {
        customGroupingDistance[spec] != nil
    }

    /// Slop used for this group, falling back to the session default.
    func tolerance(forGroup index: Int, in spec: String) -> AutoIDTolerance {
        guard let ids = groupIDs(index, in: spec) else { return tolerance }
        return groupTolerance[ids] ?? tolerance
    }

    func setTolerance(_ value: AutoIDTolerance, forGroup index: Int, in spec: String) {
        checkpoint("Tolerance", coalescing: true)
        guard let ids = groupIDs(index, in: spec) else { return }
        if value == tolerance {
            groupTolerance.removeValue(forKey: ids)
        } else {
            groupTolerance[ids] = value
        }
        recompute()
    }

    /// True when this group's numbers run against its strategy's direction.
    func isReversed(groupIndex index: Int, in spec: String) -> Bool {
        guard let ids = groupIDs(index, in: spec) else { return false }
        return groupReversed.contains(ids)
    }

    /// Sets which way the numbering runs for each of the given groups.
    ///
    /// Takes a selection rather than one group because a whole side of a
    /// rig commonly comes out backwards together — the depth or shape
    /// heuristics get the axis right and the direction wrong for all of
    /// them at once. Sets rather than toggles, so a menu item that says
    /// "Flip direction" flips a mixed selection the same way round instead
    /// of scrambling it.
    func setReversed(_ reversed: Bool, groupIndices: Set<Int>, in spec: String) {
        checkpoint("Flip direction")
        for index in groupIndices.sorted() {
            guard let ids = groupIDs(index, in: spec) else { continue }
            if reversed {
                groupReversed.insert(ids)
            } else {
                groupReversed.remove(ids)
            }
        }
        recompute()
    }

    func hasCustomTolerance(forGroup index: Int, in spec: String) -> Bool {
        guard let ids = groupIDs(index, in: spec) else { return false }
        return groupTolerance[ids] != nil
    }

    /// How many groups of this type have a shape with no obvious order.
    ///
    /// Used to point a first-time user at the types worth checking: every
    /// row otherwise looks equally settled, so the honest strategy is to
    /// open all of them, and that is what makes the tool feel like work.
    func groupsNeedingAttention(in spec: String) -> Int {
        let groups = plan.groupsBySpec[spec] ?? []
        return groups.indices.filter { needsAttention(groupIndex: $0, in: spec) }.count
    }

    /// A group whose shape has no obvious order, that the user has not yet
    /// looked at or answered.
    func needsAttention(groupIndex index: Int, in spec: String) -> Bool {
        guard let ids = groupIDs(index, in: spec) else { return false }
        // Choosing an order answers the question outright.
        guard groupOrdering[ids] == nil, !acknowledged.contains(ids) else { return false }
        return isAmbiguous(groupIndex: index, in: spec)
    }

    /// Marks a group as seen, which clears its flag and the type's count.
    ///
    /// Deliberately outside the undo snapshots: this is a record of what
    /// the user has looked at, not part of the plan, and stepping back
    /// through edits should not re-raise warnings already dealt with.
    func acknowledge(groupIndex index: Int, in spec: String) {
        guard let ids = groupIDs(index, in: spec), !acknowledged.contains(ids) else { return }
        acknowledged.insert(ids)
        objectWillChange.send()
    }

    /// True when the group bends far enough off its own axis that no order
    /// is obviously right — a U around three sides of a stage, an arc, a
    /// block — and the choice should be put to the user rather than assumed.
    func isAmbiguous(groupIndex index: Int, in spec: String) -> Bool {
        guard let ids = groupIDs(index, in: spec) else { return false }
        return MVRAutoID.isAmbiguousShape(fixtures: ids.compactMap { fixturesByID[$0] })
    }

    private func groupIDs(_ index: Int, in spec: String) -> Set<String>? {
        let groups = plan.groupsBySpec[spec] ?? []
        guard groups.indices.contains(index) else { return nil }
        return Set(groups[index])
    }

    /// Throws away every hand-made group for one type, back to clustering.
    func resetGrouping(for spec: String) {
        checkpoint("Reset grouping")
        let owned = Set(fixtures.filter { $0.gdtfSpec == spec }.map(\.id))
        manualGroups.removeAll { !$0.isDisjoint(with: owned) }
        groupOrdering = groupOrdering.filter { $0.key.isDisjoint(with: owned) }
        groupTolerance = groupTolerance.filter { $0.key.isDisjoint(with: owned) }
        groupReversed = groupReversed.filter { $0.isDisjoint(with: owned) }
        groupNames = groupNames.filter { $0.key.isDisjoint(with: owned) }
        groupStartingID = groupStartingID.filter { $0.key.isDisjoint(with: owned) }
        groupSpacing = groupSpacing.filter { $0.key.isDisjoint(with: owned) }
        typeStartingID.removeValue(forKey: spec)
        groupOrder.removeValue(forKey: spec)
        customGroupingDistance.removeValue(forKey: spec)
        recompute()
    }

    func hasManualGrouping(for spec: String) -> Bool {
        if customGroupingDistance[spec] != nil || groupOrder[spec] != nil { return true }
        let owned = Set(fixtures.filter { $0.gdtfSpec == spec }.map(\.id))
        if groupSpacing.keys.contains(where: { !$0.isDisjoint(with: owned) }) { return true }
        if groupReversed.contains(where: { !$0.isDisjoint(with: owned) }) { return true }
        if groupNames.keys.contains(where: { !$0.isDisjoint(with: owned) }) { return true }
        return manualGroups.contains { !$0.isDisjoint(with: owned) }
    }

    /// The proposed grouping, ready to draw in the 3D view — the quickest
    /// way to see that a "truss" actually spans two sides of the stage, or
    /// that the numbers run the wrong way along one.
    ///
    /// Hues cycle and brightness alternates, so groups sitting next to each
    /// other stay distinguishable. Excluded types produce no overlay and
    /// keep their normal colouring.
    func groupOverlays(for spec: String? = nil) -> [AutoIDGroupOverlay] {
        var overlays: [AutoIDGroupOverlay] = []
        var index = 0

        for candidate in typeOrder where includedTypes.contains(candidate) {
            let names = plan.groupNamesBySpec[candidate] ?? []
            for (withinType, group) in (plan.groupsBySpec[candidate] ?? []).enumerated() {
                defer { index += 1 }
                guard spec == nil || spec == candidate else { continue }

                let ids = plan.assignments
                    .filter { group.contains($0.fixtureID) }
                    .sorted { $0.newID < $1.newID }

                // Emitted even if somehow empty. When filtered to one type
                // these line up index-for-index with `groups(for:)`, which
                // is what lets selecting a row frame that group — dropping
                // one here would shift the rest and highlight the wrong one.
                let range: String
                switch (ids.first?.newID, ids.last?.newID) {
                case let (first?, last?) where first != last: range = "\(first)–\(last)"
                case let (first?, _): range = "\(first)"
                default: range = "—"
                }

                // The 3D label carries the suggested name as well as the ID
                // range: this is the one place you are looking *at* a group
                // rather than at a list of them, so the name is what tells
                // you which one you have found.
                let label = names.indices.contains(withinType)
                    ? "\(names[withinType])  \(range)"
                    : range

                overlays.append(AutoIDGroupOverlay(
                    label: label,
                    color: NSColor(
                        hue: CGFloat(index % 12) / 12,
                        saturation: 0.75,
                        brightness: index.isMultiple(of: 2) ? 0.95 : 0.65,
                        alpha: 1),
                    // Numbering order, which is what the path is showing.
                    fixtureIDs: ids.map(\.fixtureID)))
            }
        }
        return overlays
    }

    // MARK: - Applying

    /// Writes the plan through the document's own setter, so the XML and the
    /// fixture list stay in step and each change is revertible exactly like
    /// a hand edit.
    func apply(to document: MVRDocument) {
        for assignment in plan.assignments where assignment.isChanged {
            document.setFixtureID(assignment.newID, forFixtureAtID: assignment.fixtureID)
        }

        // Group names ride along, so they can be written to <UserData> on
        // export. Existing names for fixtures this run didn't touch are
        // kept: a run over one type shouldn't wipe another's names.
        var names = document.groupNames
        for spec in typeOrder where includedTypes.contains(spec) {
            for (index, group) in (plan.groupsBySpec[spec] ?? []).enumerated() {
                let name = name(forGroup: index, in: spec)
                for fixtureID in group { names[fixtureID] = name }
            }
        }
        document.setGroupNames(names)

        // Written into <UserData> on export, so re-opening the file
        // resumes this run instead of starting it over.
        document.setAutoIDSession(hasCorrections ? storedSession : nil)
    }
}


private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
