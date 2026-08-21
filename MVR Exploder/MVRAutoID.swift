import Foundation

/// How numbering runs through the fixtures of one group.
///
/// A straight truss only has one sensible answer, but plenty of positions
/// aren't straight — a U of fixtures around three sides of a stage, or a
/// block several rows deep — and there the order is a judgement call rather
/// than something to infer. `MVRAutoID.isAmbiguousShape` flags those so the
/// choice can be put to the user instead of guessed at.
enum AutoIDOrderStrategy: String, CaseIterable, Identifiable, Hashable {
    /// Across the stage, ties broken top-down. Right for a straight truss.
    case leftToRight
    /// Follows the shape from one end to the other, hopping to the nearest
    /// unused fixture each time. This is the one for a U: down one leg,
    /// along the back, up the other leg.
    case aroundShape
    /// Rows top-down, each row running opposite to the one above, the way
    /// you'd number a block of fixtures without walking back to the start.
    case zigZagRows
    /// Rows again, but every row starting from the same side — across,
    /// back to the start, across again. What a pixel array or a video
    /// surface usually wants, where alternating rows would reverse the
    /// mapping on every other line.
    case rowsSameDirection
    /// Straight down, ties broken left to right — for vertical ladders.
    case topToBottom
    /// One column all the way down, then back to the top of the next.
    ///
    /// For a tower carrying two or more fixtures at every height: `.topToBottom`
    /// reads those across before dropping a level, which numbers the tower in
    /// pairs. This numbers each vertical line in full before starting the next.
    ///
    /// Last in the list deliberately — `suggestedStrategy` keeps the first
    /// strictly-shortest path, and returning to the top of a tower is a long
    /// way, so adding this can't quietly displace an existing suggestion.
    case columnsTopToBottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leftToRight: return "Left to right"
        case .aroundShape: return "Around the shape (U)"
        case .zigZagRows: return "Zig-zag rows"
        case .rowsSameDirection: return "Rows, all the same way"
        case .topToBottom: return "Top to bottom"
        case .columnsTopToBottom: return "Tower (down each column)"
        }
    }

    var detail: String {
        switch self {
        case .leftToRight: return "Across the stage, top-down where fixtures share a position."
        case .aroundShape: return "Follows the run from one end round to the other."
        case .zigZagRows: return "Row by row, alternating direction each row."
        case .rowsSameDirection: return "Across, then back to the same side and across again."
        case .topToBottom: return "Down the group, left to right at each height."
        case .columnsTopToBottom: return "For a tower carrying more than one fixture at each height: all the way down one column, then down the next."
        }
    }
}

/// How close two fixtures must be on an axis to count as sharing a position
/// when ordering.
///
/// This is the difference between "one column of six" and "six separate
/// positions". Rigging is never exact: on a real U of fixtures, one leg sat
/// at X = 9.42, 9.43, 9.51, 9.51, 9.52, 9.55 — a spread of 13cm that a
/// tighter figure read as six distinct columns, scrambling the leg's order.
/// Per axis because the slop isn't uniform: hanging positions vary far more
/// in height than a floor package varies in depth.
struct AutoIDTolerance: Codable, Equatable {
    var x: Double = 0.2
    var y: Double = 0.2
    var z: Double = 0.2

    static let `default` = AutoIDTolerance()
}

/// Spare IDs left in the numbering, so there is room to add fixtures
/// later without renumbering everything after them.
///
/// Two independent gaps because they answer different questions. A gap
/// between groups leaves room to hang another two fixtures on a truss; a
/// gap between fixtures leaves room to slot one in *between* two that are
/// already there. A rig that pixel-maps by position wants the second; most
/// shows want only the first, and plenty want neither — hence a tickbox on
/// each rather than a number that has to be set to zero to mean "off".
struct AutoIDGaps: Codable, Equatable {
    var betweenGroups = false
    /// Spare IDs left after each group before the next one starts.
    var groupGap = 10
    var betweenFixtures = false
    /// Spare IDs left after each fixture before the next one.
    var fixtureGap = 1

    var groupSpacing: Int { betweenGroups ? max(0, groupGap) : 0 }
    /// How much each fixture advances the count. One more than the gap:
    /// a gap of 1 numbers 1001, 1003, 1005.
    var fixtureStep: Int { betweenFixtures ? max(1, fixtureGap + 1) : 1 }

    var isActive: Bool { groupSpacing > 0 || fixtureStep > 1 }
}

/// Settings for one auto-ID run.
struct AutoIDOptions {
    /// Fallback slop for groups without their own setting.
    var tolerance = AutoIDTolerance.default

    /// Per-group slop, keyed by exact membership like `groupOrdering`. How
    /// much a position wanders is a property of that position, not the file
    /// — a hung ladder and a floor package in the same show need different
    /// figures — so it's set per group rather than globally.
    var groupTolerance: [Set<String>: AutoIDTolerance] = [:]

    /// Where the first block begins. User-set, because whether a rig starts
    /// at 1 or 1001 is a house convention, not something to infer.
    var startingID: Int = 1001

    /// GDTF specs in the order their blocks are allocated — the first gets
    /// the lowest numbers. User-ordered (drag to rearrange); anything not
    /// listed falls to the end in descending fixture count.
    var typeOrder: [String] = []

    /// Only these types are renumbered. Everything else keeps its ID, and
    /// those retained IDs are checked against for collisions.
    var includedTypes: Set<String> = []


    /// How far apart two fixtures of a type can sit and still count as one
    /// group, in metres, keyed by spec. Overrides the distance derived from
    /// the type's own spacing.
    ///
    /// Per type because the automatic figure is a guess from median
    /// spacing, and a rig routinely breaks it: fixtures paired tightly on a
    /// tower cluster as pairs rather than as the four towers a user sees.
    /// One number for the whole file can't serve both a tower and a truss,
    /// so each type gets its own.
    var groupingDistance: [String: Double] = [:]

    /// How to run the numbers within particular groups, keyed by exact
    /// membership. A group whose shape isn't a simple line has no single
    /// obvious order, so the choice is the user's; anything not listed
    /// falls back to `.leftToRight`. Keying by the fixture set means an
    /// override lapses by itself if that group is later merged or split
    /// into something different.
    var groupOrdering: [Set<String>: AutoIDOrderStrategy] = [:]

    /// Names the user has typed, keyed by exact membership like the other
    /// per-group overrides, so one lapses back to the suggestion if that
    /// group is later merged or split into something different.
    var groupNames: [Set<String>: String] = [:]

    /// A clustering distance for one group only, keyed by that group's
    /// exact membership.
    ///
    /// For the common case where a file groups well apart from one blob:
    /// the type-wide slider would fix the blob and ruin everything else,
    /// so the blob gets its own figure and the rest is left alone.
    ///
    /// Stable across recomputes because the automatic pass is
    /// deterministic — the same blob reforms with the same membership every
    /// time, so the key keeps matching even though re-splitting it produces
    /// groups that no longer carry that membership.
    var groupSpacing: [Set<String>: Double] = [:]

    /// A block start the user has pinned for a type, overriding the
    /// automatic allocation. Everything not pinned flows around it.
    var typeStartingID: [String: Int] = [:]

    /// A first ID pinned for one group, keyed by exact membership like the
    /// other per-group overrides. Groups after it continue from there.
    var groupStartingID: [Set<String>: Int] = [:]

    /// Fixture types numbered as one. An ACME Pixel Line 100 and a Pixel
    /// Line 50 are the same instrument in two lengths, and a rig treats
    /// them as one system — so they share a block of IDs, group together,
    /// and run in one sequence rather than two interleaved ones.
    ///
    /// Each set is one family. A spec in no set stands alone as before.
    var mergedTypes: [Set<String>] = []

    /// Names an earlier run wrote into the file, per fixture id. Used as
    /// the suggestion when every fixture of a group carries the same one,
    /// so re-opening the tool doesn't throw away names already settled on.
    var storedNames: [String: String] = [:]

    /// Groups whose numbering runs backwards, keyed by exact membership.
    ///
    /// Separate from `groupOrdering` rather than four more strategies:
    /// which way round a run goes is orthogonal to the shape it follows,
    /// and a truss that is simply numbered from the wrong end shouldn't
    /// need a different shape picked to fix it.
    var groupReversed: Set<Set<String>> = []

    /// Hand-set order of a type's groups, keyed by spec, each entry a group
    /// identified by its exact membership. Groups not listed keep their
    /// automatic position after the listed ones, so a merge or split that
    /// changes membership lapses that group's place rather than the lot.
    var groupOrder: [String: [Set<String>]] = [:]

    /// Groups the user has fixed by hand, each a set of fixture ids treated
    /// as one truss. Clustering is only ever a guess — on real files it
    /// convinces for perhaps two thirds of fixture types — so merges and
    /// splits are recorded here and honoured ahead of it. Members are
    /// removed from automatic clustering; whatever is left still clusters
    /// normally around them.
    var manualGroups: [Set<String>] = []

    /// Spare IDs left between groups and between fixtures.
    var gaps = AutoIDGaps()
}

/// What an auto-ID run would do, computed without changing anything.
struct AutoIDPlan {
    struct Assignment: Identifiable {
        let fixtureID: String
        let name: String
        let spec: String
        let oldID: Int?
        let newID: Int
        /// Which detected group (truss/position) within its type, in
        /// numbering order — also what the 3D preview colours by.
        let groupIndex: Int

        var id: String { fixtureID }
        var isChanged: Bool { oldID != newID }
    }

    struct TypeSummary: Identifiable {
        let spec: String
        let fixtureCount: Int
        let groupCount: Int
        let groupSizes: [Int]
        let blockSize: Int
        let firstID: Int
        let lastID: Int
        /// The clustering distance used, in metres — surfaced so the
        /// preview can show why a type grouped the way it did.
        let groupingDistance: Double
        /// Fixtures with no <Matrix>, parked at the end of the block.
        let unpositionedCount: Int

        var id: String { spec }
    }

    let assignments: [Assignment]
    let types: [TypeSummary]
    /// Fixture ids per group per type, for colouring the preview.
    let groupsBySpec: [String: [[String]]]
    /// The LX bar each group hangs on, index-aligned with `groupsBySpec`,
    /// and nil for anything that isn't an overhead bar. Bars are numbered
    /// across the whole rig, so one type's list skips the bars it isn't on
    /// — which looks like a gap from inside that list and needs explaining.
    let lxNumbersBySpec: [String: [Int?]]
    /// A suggested name per group, index-aligned with `groupsBySpec`.
    /// Derived from where the group sits in the rig and what shape it is —
    /// "Downstage Left Tower" identifies a group in a way "3" does not.
    let groupNamesBySpec: [String: [String]]
    /// Proposed IDs that would collide — with each other, or with a fixture
    /// of an excluded type that keeps its existing ID.
    let collisions: [Int]

    var changedCount: Int { assignments.filter(\.isChanged).count }
}

/// Works out Fixture IDs from where fixtures actually are.
///
/// The shape of the problem, measured on real festival files: IDs are
/// grouped by fixture type, and within a type they run truss by truss. MVR
/// layers can't supply those trusses — one real file's "WINGS" layer spans
/// 115 metres and holds every wing tower — so groups are found from the
/// positions themselves.
enum MVRAutoID {

    // MARK: - Geometry helpers

    /// A fixture position in metres, in the MVR's frame (X across, Y depth,
    /// Z up).
    private struct Point {
        let x: Double
        let y: Double
        let z: Double

        func distance(to other: Point) -> Double {
            let dx = x - other.x, dy = y - other.y, dz = z - other.z
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }
    }

    private struct Placed {
        let fixture: MVRFixture
        let point: Point
    }

    /// Slack used where a fixed figure is fine — comparing extents, not
    /// deciding whether two fixtures share a position (that's
    /// `AutoIDTolerance`, which the user can adjust).
    private static let geometryEpsilon = 0.05

    // MARK: - Planning

    static func plan(fixtures: [MVRFixture], options: AutoIDOptions) -> AutoIDPlan {
        let included = fixtures.filter { options.includedTypes.contains($0.gdtfSpec) }
        guard !included.isEmpty else {
            return AutoIDPlan(assignments: [], types: [], groupsBySpec: [:], lxNumbersBySpec: [:], groupNamesBySpec: [:], collisions: [])
        }

        // Merged families collapse to one key here, and everything
        // downstream — grouping, blocks, naming, the preview — keys off it
        // without needing to know a merge happened.
        let canonical = canonicalSpecs(options: options)
        func family(_ spec: String) -> String { canonical[spec] ?? spec }

        var bySpec: [String: [MVRFixture]] = [:]
        for fixture in included { bySpec[family(fixture.gdtfSpec), default: []].append(fixture) }

        var assignments: [AutoIDPlan.Assignment] = []
        var summaries: [AutoIDPlan.TypeSummary] = []
        var groupsBySpec: [String: [[String]]] = [:]
        var namingRuns: [NamingRun] = []
        var pending: [PendingType] = []

        // One frame for the whole run, not per type: a type whose fixtures
        // all sit stage right would otherwise have its leftmost group named
        // "Left". Sides and depths only mean something against the rig.
        let frame = NameFrame(fixtures: included)

        // Built once from every fixture in the run, so one type's marginal
        // run can be confirmed by another type's solid one on the same bar.
        let evidence = TrussEvidence(
            fixtures: split(included).placed,
            tolerance: options.tolerance)

        for spec in orderedSpecs(bySpec: bySpec, options: options) {
            guard let group = bySpec[spec] else { continue }

            let (placed, unplaced) = split(group)
            let points = placed.map(\.point)
            let chosenDistance = options.groupingDistance[spec]
            let distance = chosenDistance.map { max($0, 0.01) } ?? groupingDistance(for: points)
            var clusters = orderedClusters(
                placed,
                distance: distance,
                manualGroups: options.manualGroups,
                groupOrdering: options.groupOrdering,
                tolerance: options.tolerance,
                groupTolerance: options.groupTolerance,
                groupReversed: options.groupReversed,
                groupSpacing: options.groupSpacing,
                // Dragging the spacing slider is the user saying how this
                // type groups. Repairing on top of that would both override
                // them and break what the control promises — at the far
                // right it must give one group, and a repair that keeps
                // splitting takes the top of the travel away.
                repairChains: chosenDistance == nil,
                evidence: evidence)

            if let wanted = options.groupOrder[spec] {
                clusters = reordered(clusters, following: wanted)
            }

            // Blocks are sized per type: a hundred is plenty for most, but a
            // type with more fixtures than that needs the next size up or it
            // would run straight into its neighbour's block.
            // Nothing to sort them by spatially, so they go last in a stable,
            // human-readable order rather than in whatever order the file had.
            let trailing = unplaced.sorted {
                ($0.name, $0.originalUUID) < ($1.name, $1.originalUUID)
            }

            // Held back rather than numbered here: a pinned block can sit
            // anywhere, so nothing can be allocated until every type's size
            // is known and the pinned ranges are reserved.
            pending.append(PendingType(
                spec: spec,
                clusters: clusters,
                trailing: trailing,
                fixtureCount: group.count,
                idSpan: numberedSpan(
                    groupSizes: clusters.map(\.count) + [trailing.count],
                    gaps: options.gaps),
                groupingDistance: distance))
            namingRuns.append(NamingRun(
                spec: spec, clusters: clusters, unpositioned: trailing.count))
        }

        let step = options.gaps.fixtureStep
        let groupGap = options.gaps.groupSpacing

        for placement in allocate(pending, options: options) {
            let entry = placement.type
            // The next free ID, not the next one to hand out: with a gap
            // between fixtures those differ, and it's the free one that
            // the following group has to start clear of.
            var next = placement.start
            var groupIDs: [[String]] = []

            /// Numbers one group and leaves `next` one past its last ID.
            func number(_ members: [MVRFixture], groupIndex: Int) {
                guard !members.isEmpty else { return }
                // A group can pin its own first ID; the ones after it carry
                // on from wherever that leaves off.
                if let pinned = options.groupStartingID[Set(members.map(\.id))] {
                    next = max(1, pinned)
                } else if groupIndex > 0 {
                    next += groupGap
                }
                groupIDs.append(members.map(\.id))
                var id = next
                for fixture in members {
                    assignments.append(makeAssignment(
                        fixture, spec: entry.spec, newID: id, groupIndex: groupIndex))
                    id += step
                }
                next = id - step + 1
            }

            for (index, cluster) in entry.clusters.enumerated() {
                number(cluster.map(\.fixture), groupIndex: index)
            }
            number(entry.trailing, groupIndex: entry.clusters.count)

            groupsBySpec[entry.spec] = groupIDs
            summaries.append(AutoIDPlan.TypeSummary(
                spec: entry.spec,
                fixtureCount: entry.fixtureCount,
                groupCount: groupIDs.count,
                groupSizes: groupIDs.map(\.count),
                blockSize: placement.blockSize,
                firstID: placement.start,
                lastID: max(placement.start, next - 1),
                groupingDistance: entry.groupingDistance,
                unpositionedCount: entry.trailing.count))
        }

        let lx = lxNumbers(for: namingRuns, frame: frame)
        return AutoIDPlan(
            assignments: assignments,
            types: summaries,
            groupsBySpec: groupsBySpec,
            lxNumbersBySpec: namingRuns.reduce(into: [:]) { result, run in
                result[run.spec] = run.clusters.map { lx[Set($0.map(\.fixture.id))] }
                    + Array(repeating: nil, count: run.unpositioned > 0 ? 1 : 0)
            },
            groupNamesBySpec: names(
                for: namingRuns,
                frame: frame,
                lx: lx,
                overrides: options.groupNames,
                stored: options.storedNames),
            collisions: collisions(in: assignments, allFixtures: fixtures, options: options))
    }

    /// `spec` is the *family* the fixture was numbered under, which is its
    /// own type unless it has been merged with others.
    private static func makeAssignment(
        _ fixture: MVRFixture, spec: String, newID: Int, groupIndex: Int
    ) -> AutoIDPlan.Assignment {
        AutoIDPlan.Assignment(
            fixtureID: fixture.id,
            name: fixture.name,
            spec: spec,
            oldID: fixture.currentFixtureID,
            newID: newID,
            groupIndex: groupIndex)
    }

    /// Maps every spec of a merged family onto the one that represents it —
    /// whichever member the user has ordered first, so merging does not
    /// silently move a family's block.
    private static func canonicalSpecs(options: AutoIDOptions) -> [String: String] {
        var rank: [String: Int] = [:]
        for (index, spec) in options.typeOrder.enumerated() { rank[spec] = index }

        var result: [String: String] = [:]
        for family in options.mergedTypes where family.count > 1 {
            let representative = family.min {
                (rank[$0] ?? Int.max, $0) < (rank[$1] ?? Int.max, $1)
            }
            guard let representative else { continue }
            for spec in family { result[spec] = representative }
        }
        return result
    }

    /// User order first, then anything left over by descending count, so a
    /// newly-appearing type lands somewhere sensible rather than at random.
    private static func orderedSpecs(bySpec: [String: [MVRFixture]], options: AutoIDOptions) -> [String] {
        let known = options.typeOrder.filter { bySpec[$0] != nil }
        let rest = bySpec.keys
            .filter { !known.contains($0) }
            .sorted { (bySpec[$0]?.count ?? 0, $1) > (bySpec[$1]?.count ?? 0, $0) }
        return known + rest
    }

    private static func split(_ fixtures: [MVRFixture]) -> (placed: [Placed], unplaced: [MVRFixture]) {
        var placed: [Placed] = []
        var unplaced: [MVRFixture] = []
        for fixture in fixtures {
            if let position = fixture.position3D {
                // MVR stores millimetres; everything here is metres.
                placed.append(Placed(fixture: fixture, point: Point(
                    x: position.x / 1000, y: position.y / 1000, z: position.z / 1000)))
            } else {
                unplaced.append(fixture)
            }
        }
        return (placed, unplaced)
    }

    // MARK: - Naming

    /// The rig's own extents, against which a group's position is described.
    private struct NameFrame {
        let x: ClosedRange<Double>
        let y: ClosedRange<Double>
        let z: ClosedRange<Double>
        /// Where the bulk of the rig sits across the stage, from the 10th
        /// to the 90th percentile of X — the main body, ignoring outliers.
        let coreX: ClosedRange<Double>

        init(fixtures: [MVRFixture]) {
            let points = MVRAutoID.split(fixtures).placed.map(\.point)
            func span(_ values: [Double]) -> ClosedRange<Double> {
                let low = values.min() ?? 0, high = values.max() ?? 0
                return low...max(high, low)
            }
            x = span(points.map(\.x))
            y = span(points.map(\.y))
            z = span(points.map(\.z))

            let across = points.map(\.x).sorted()
            if across.count >= 10 {
                coreX = across[across.count / 10]...across[across.count * 9 / 10]
            } else {
                coreX = x
            }
        }

        /// True for a position sitting out beyond the main body of the rig
        /// — a wing.
        ///
        /// Being outside the core is not enough on its own: on one real rig
        /// a single floor fixture sat 0.2m past it, and on another a
        /// downstage tower sat 1.7m past a core 95m wide. What marks a wing
        /// is the *gap*. On CV26 the core reaches 9.3m and the wings start
        /// at 22.2m — 13m of nothing in between, against a core half-width
        /// of 9.3m. Requiring that gap to be a real fraction of the body's
        /// own width separates the two cases cleanly (1.39 against 0.03).
        func isWing(_ points: [Double]) -> Bool {
            guard let low = points.min(), let high = points.max() else { return false }
            let halfWidth = (coreX.upperBound - coreX.lowerBound) / 2
            guard halfWidth > 0.01 else { return false }

            let beyond: Double
            if low > coreX.upperBound {
                beyond = low - coreX.upperBound
            } else if high < coreX.lowerBound {
                beyond = coreX.lowerBound - high
            } else {
                return false
            }
            return beyond >= halfWidth * MVRAutoID.wingGapFraction
        }

        /// Where a value sits across a span, 0 at one end and 1 at the
        /// other. A rig with no spread on an axis reports the middle rather
        /// than dividing by zero.
        func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
            let width = range.upperBound - range.lowerBound
            guard width > 0.01 else { return 0.5 }
            return (value - range.lowerBound) / width
        }
    }

    /// One type's clusters, held aside so naming can run once over the
    /// whole run rather than type by type.
    private struct NamingRun {
        let spec: String
        let clusters: [[Placed]]
        let unpositioned: Int
    }

    /// Overhead bars are named by the house convention — LX1, LX2 — rather
    /// than described.
    ///
    /// The numbers have to be assigned across the **whole run**, not per
    /// type: LX2 is a physical bar, and the four types hanging on it all
    /// belong to the same LX2. Bars are found by banding truss depths
    /// together, so two types on the one bar land in one band even though
    /// their centroids differ by a few centimetres.
    private static let lxBandTolerance = 1.0

    private static func lxNumbers(for runs: [NamingRun], frame: NameFrame) -> [Set<String>: Int] {
        var trusses: [(key: Set<String>, depth: Double)] = []
        for run in runs {
            // Overhead bars only. A floor package is a truss by shape but
            // is not an LX, and numbering one would both mislabel it and
            // push the real bars' numbers up. Same for a wing truss, which
            // is its own position rather than one of the bars over stage.
            for cluster in run.clusters
            where shape(of: cluster) == "Truss"
                && isOverhead(cluster, frame: frame)
                && !frame.isWing(cluster.map(\.point.x)) {
                let depths = cluster.map(\.point.y)
                trusses.append((Set(cluster.map(\.fixture.id)),
                                depths.reduce(0, +) / Double(depths.count)))
            }
        }
        guard !trusses.isEmpty else { return [:] }

        // Single-linkage along depth alone: a gap wider than the tolerance
        // starts a new bar.
        var bands: [[Double]] = []
        for depth in trusses.map(\.depth).sorted() {
            if let last = bands.last?.last, depth - last <= lxBandTolerance {
                bands[bands.count - 1].append(depth)
            } else {
                bands.append([depth])
            }
        }

        // LX1 is the downstage end — the same end the numbering runs from.
        let ordered = bands

        var numbers: [Set<String>: Int] = [:]
        for truss in trusses {
            guard let index = ordered.firstIndex(where: { band in
                band.contains { abs($0 - truss.depth) < 1e-9 }
            }) else { continue }
            numbers[truss.key] = index + 1
        }
        return numbers
    }

    /// Names every group in the run, then makes them unique within a type.
    ///
    /// Duplicates are expected and fine — four matching towers really are
    /// four "Left Tower"s to look at — so they take a trailing number in
    /// numbering order rather than being described more finely and losing
    /// the plain-language read. A name the user has set is left exactly as
    /// typed, including a duplicate: that is their call to make.
    private static func names(
        for runs: [NamingRun],
        frame: NameFrame,
        lx: [Set<String>: Int],
        overrides: [Set<String>: String],
        stored: [String: String]
    ) -> [String: [String]] {
        var result: [String: [String]] = [:]

        for run in runs {
            var proposed: [(name: String, isUserSet: Bool)] = run.clusters.map { cluster in
                let key = Set(cluster.map(\.fixture.id))
                // Trimmed here as well as at the call site: a name of pure
                // whitespace would otherwise render as a blank row.
                if let custom = overrides[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !custom.isEmpty {
                    return (custom, true)
                }

                // A name already in the file wins over a fresh suggestion,
                // but only where the whole group agrees on it — a group
                // that has since been split or merged spans two old names
                // and is better off re-described than given one of them.
                if let settled = settledName(of: cluster, stored: stored) { return (settled, true) }

                let parts = descriptorParts(of: cluster, frame: frame)

                // An LX number already encodes depth — bars are numbered in
                // depth order — so repeating it in brackets can only ever be
                // redundant, and on a rig where two bars fall in the same
                // third it reads as a bug: "LX1 (Downstage Truss)" above
                // "LX3 (Downstage Truss)". Only the side survives, which is
                // what actually tells two halves of one bar apart.
                if let number = lx[key] {
                    return (parts.side.map { "LX\(number) (\($0))" } ?? "LX\(number)", false)
                }
                return (parts.described, false)
            }
            if run.unpositioned > 0 { proposed.append(("No position", false)) }

            var counts: [String: Int] = [:]
            for entry in proposed where !entry.isUserSet { counts[entry.name, default: 0] += 1 }

            var seen: [String: Int] = [:]
            result[run.spec] = proposed.map { entry in
                guard !entry.isUserSet, (counts[entry.name] ?? 0) > 1 else { return entry.name }
                seen[entry.name, default: 0] += 1
                return "\(entry.name) \(seen[entry.name] ?? 1)"
            }
        }
        return result
    }

    /// The one name every fixture of a group already carries, if there is
    /// one.
    private static func settledName(of cluster: [Placed], stored: [String: String]) -> String? {
        guard !stored.isEmpty, !cluster.isEmpty else { return nil }
        var found: String?
        for placed in cluster {
            guard let name = stored[placed.fixture.id] else { return nil }
            if let found, found != name { return nil }
            found = name
        }
        return found
    }

    /// What a group is, from which axis it runs along.
    ///
    /// One axis has to clearly dominate to earn a name. An earlier version
    /// took whichever axis passed 90% of the longest, which let a
    /// near-square group be called a Tower while it was in fact wider than
    /// tall — 2 of 16 on one real file. Anything without a dominant axis is
    /// a Block, which is honest.
    private static func shape(of cluster: [Placed]) -> String {
        guard !cluster.isEmpty else { return "Position" }
        let points = cluster.map(\.point)
        func extent(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }

        let width = extent(points.map(\.x))
        let depth = extent(points.map(\.y))
        let height = extent(points.map(\.z))
        let longest = max(width, max(depth, height))
        let dominance = 1.25

        if longest < 0.75 { return "Position" }
        if height == longest, height > max(width, depth) * dominance { return "Tower" }
        if width == longest, width > max(depth, height) * dominance { return "Truss" }
        if depth == longest, depth > max(width, height) * dominance { return upDownTruss }
        return "Block"
    }

    /// False for a group sitting in the bottom of the rig — the same test
    /// that earns the "Floor" word, kept in one place so the two can't
    /// disagree about what counts as floor level.
    private static func isOverhead(_ cluster: [Placed], frame: NameFrame) -> Bool {
        guard frame.z.upperBound - frame.z.lowerBound > 1 else { return true }
        let heights = cluster.map(\.point.z)
        let mean = heights.reduce(0, +) / Double(max(heights.count, 1))
        return frame.fraction(mean, in: frame.z) >= 0.2
    }

    private static func descriptorParts(
        of cluster: [Placed],
        frame: NameFrame
    ) -> (described: String, side: String?) {
        guard !cluster.isEmpty else { return ("Empty", nil) }

        let points = cluster.map(\.point)
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        func extent(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }

        var parts: [String] = []

        let form = shape(of: cluster)

        // Depth, using the same convention as the numbering: the end it
        // starts from is downstage.
        let front = frame.fraction(mean(points.map(\.y)), in: frame.y)
        // Meaningless for something that spans the depth of the stage.
        if form == upDownTruss {
            // no depth word
        } else if front < 0.33 {
            parts.append("Downstage")
        } else if front > 0.67 {
            parts.append("Upstage")
        } else if frame.y.upperBound - frame.y.lowerBound > 0.01 {
            parts.append("Mid")
        }

        var side: String?

        // Side, but only when the group doesn't span the stage itself —
        // a side is meaningless for a truss reaching both.
        //
        // **Stage left and right are from the performer's point of view**,
        // standing on stage looking at the audience — so stage left is the
        // audience's right. Lower X is stage *right*, which is the opposite
        // way round from `.leftToRight`'s ordering: that strategy runs
        // along ascending X, which is house left to right as drawn in plan.
        // Two different conventions, both correct in their own context.
        let stageWidth = frame.x.upperBound - frame.x.lowerBound
        if stageWidth > 0.01, extent(points.map(\.x)) < stageWidth * 0.6 {
            let across = frame.fraction(mean(points.map(\.x)), in: frame.x)
            side = across < 0.33 ? "Right" : (across > 0.67 ? "Left" : "Centre")
        }
        if let side { parts.append(side) }

        // Height only when it sets the group apart: a floor package among
        // hung fixtures is worth calling out, a truss at truss height isn't.
        if !isOverhead(cluster, frame: frame) {
            parts.append("Floor")
        }

        // Out past the main body of the rig, which is what a wing is.
        if frame.isWing(points.map(\.x)) { parts.append("Wing") }

        parts.append(form)
        return (parts.joined(separator: " "), side)
    }

    // MARK: - Grouping

    /// Clustering distance derived from the type's own spacing.
    ///
    /// A single distance for the whole file does not work: measured on one
    /// festival rig, blinders sit 1.0m apart while the JDC Bursts sit 2.8m
    /// apart, so 2m split the Bursts into 26 groups of one while 4m chained
    /// 79 blinders into a single 67m blob. Scaling each type by its own
    /// median nearest-neighbour distance keeps both honest.
    private static func groupingDistance(for points: [Point]) -> Double {
        guard points.count >= 2 else { return 1 }

        var nearest: [Double] = []
        nearest.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            var best = Double.greatestFiniteMagnitude
            for (other, candidate) in points.enumerated() where other != index {
                best = min(best, point.distance(to: candidate))
            }
            if best.isFinite { nearest.append(best) }
        }
        guard !nearest.isEmpty else { return 1 }

        nearest.sort()
        let median = nearest[nearest.count / 2]
        return max(median * 2.5, 0.5)
    }

    /// The span of grouping distances that produce different results for one
    /// type, alongside the automatic choice.
    ///
    /// Below `minimum` every fixture is alone; at `maximum` the type is a
    /// single group. Those are the shortest and longest edges of the minimum
    /// spanning tree, which for single-linkage are exactly the two ends of
    /// the useful range — so a slider over it reaches every grouping the
    /// clustering can produce, with no dead travel at either end.
    static func groupingBounds(fixtures: [MVRFixture]) -> (auto: Double, minimum: Double, maximum: Double)? {
        let points = split(fixtures).placed.map(\.point)
        guard points.count >= 2 else { return nil }

        let edges = spanningEdges(points)
        guard let shortest = edges.min(), let longest = edges.max(), longest > 0 else { return nil }

        // A shade either side of the real edges: the ends of a slider are
        // reconstructed from its position, and landing a hair under the
        // longest edge would leave the top of the travel showing two groups
        // rather than the one it promises.
        let minimum = max(0.01, shortest * 0.9)
        let auto = groupingDistance(for: points)
        // Median spacing can exceed the longest edge on a scattered type,
        // where the automatic answer is already one group. The range has to
        // cover it or the handle sits pinned past its own maximum.
        return (auto, minimum, max(longest * 1.05, max(minimum * 1.5, auto)))
    }

    /// Minimum spanning tree edge lengths by Prim's — O(n^2), the same order
    /// as the clustering pass itself, so asking for the bounds costs no more
    /// than one regroup.
    private static func spanningEdges(_ points: [Point]) -> [Double] {
        var best = points.map { points[0].distance(to: $0) }
        var used = [Bool](repeating: false, count: points.count)
        used[0] = true

        var edges: [Double] = []
        edges.reserveCapacity(points.count - 1)

        for _ in 1..<points.count {
            var pick = -1
            for index in points.indices where !used[index] {
                if pick < 0 || best[index] < best[pick] { pick = index }
            }
            guard pick >= 0 else { break }

            used[pick] = true
            edges.append(best[pick])
            for index in points.indices where !used[index] {
                best[index] = min(best[index], points[pick].distance(to: points[index]))
            }
        }
        return edges
    }

    /// Single-linkage clustering: fixtures within `distance` of each other
    /// share a group. Suits trusses specifically — an evenly-spaced run
    /// separated from its neighbours by a much larger gap — without needing
    /// to know how many groups to expect.
    private static func clusters(_ placed: [Placed], distance: Double) -> [[Placed]] {
        guard !placed.isEmpty else { return [] }

        var parent = Array(0..<placed.count)
        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        func union(_ a: Int, _ b: Int) {
            let (ra, rb) = (root(a), root(b))
            if ra != rb { parent[ra] = rb }
        }

        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count where placed[i].point.distance(to: placed[j].point) <= distance {
                union(i, j)
            }
        }

        var buckets: [Int: [Placed]] = [:]
        for index in placed.indices { buckets[root(index), default: []].append(placed[index]) }
        // Sorted by root, which is a plain index and so the same every
        // time. Taking `buckets.values` as they come made the whole run
        // non-reproducible: Swift seeds its hashing per process, so the
        // same file with the same settings could number differently from
        // one launch to the next wherever anything downstream broke a tie
        // by the order the clusters arrived in.
        return buckets.sorted { $0.key < $1.key }.map(\.value)
    }

    // MARK: - Collinear repair

    /// How thick a cluster may be across its second axis before it stops
    /// being believable as a single run. A real truss measures 13.5 x 0.0 x
    /// 0.0; the blob this repairs measured 23.6 x 12.5 x 11.5.
    private static let runThickness = 0.25

    /// How much of the type's own bounding box one cluster has to fill, on
    /// how many axes, before it is treated as chained rather than real.
    ///
    /// Thickness alone cannot decide this. Measured on PKP, legitimate
    /// 24-fixture tower clusters run 4.9 x 3.5 x 3.5 — a second-axis ratio
    /// of 0.72, *higher* than the CV26 blob's 0.53 — so a ratio test either
    /// misses the blob or shreds the towers. What separates them is scale:
    /// the blob fills 100% of its type's depth and 100% of its height,
    /// while a tower fills a few percent of a rig. A cluster that spans
    /// nearly the whole type on two axes is not a position, it is a chain.
    private static let blobSpanFraction = 0.7
    private static let blobSpanAxes = 2

    /// A second, independent reason to look at a cluster: it is spread
    /// across its own fixture spacing, so it is more than one line.
    ///
    /// Thickness relative to *length* cannot see this. A run of Sceptrons
    /// along a stage edge with a second, shorter run a metre upstage
    /// measures 57.0 x 1.0 x 0.0 — proportionally that is a textbook thin
    /// truss, and the ratio gate never gave it a second look. But the
    /// fixtures sit on 1.00m centres, so a metre of depth spread is a whole
    /// pitch: a single truss's fixtures are collinear to well within one.
    ///
    /// Judged against the type's own pitch, so a rig on 0.3m centres and
    /// one on 2m centres are each measured by their own spacing.
    private static let parallelRowPitchFraction = 0.9

    /// And only for something long enough to hold rows worth separating,
    /// measured in fixture pitches rather than metres or proportion.
    ///
    /// Without this the test fires on any tight clump: a run of 9 JDC1s is
    /// 0.82 x 0.38 x 0.18m on a 0.26m pitch, so its width is 1.46 pitches
    /// and it was being cut into rows of three. It is only **3 pitches
    /// long** — three fixtures end to end are not two rows of anything.
    ///
    /// Length in pitches rather than aspect ratio: aspect also separates
    /// the JDC clump (2.2) from the Sceptron line (57), but it throws away
    /// a broad block of parallel rows — one real 132-fixture group is
    /// 22.3 x 13.3m, an aspect of 1.7, and is genuinely seven rows. In
    /// pitches it is 22 long, so this admits it while still rejecting the
    /// clump.
    private static let parallelRowMinLength = 8.0

    /// What a real hanging position looks like, used to check a proposed
    /// run before it is believed.
    ///
    /// A truss carries fixtures at regular intervals along its length. That
    /// is the property to test against, rather than more shape ratios: two
    /// fixtures 24m apart that merely share a height are not a truss, they
    /// are a coincidence — and CV26 produced several of those once the axis
    /// buckets were permissive enough to find its real trusses.
    ///
    /// `runEvenness` allows for a gap where a fixture is missing from an
    /// otherwise regular run; `runPitchFactor` measures against how this
    /// type actually hangs, so a rig on 1m centres and one on 4m centres
    /// are both judged by their own spacing.
    private static let runEvenness = 2.5
    private static let runPitchFactor = 4.0
    private static let minimumRunLength = 3

    /// A shorter run is allowed when other fixture types vouch for the
    /// truss it sits on. Two is the floor: one fixture is a position, not a
    /// run, and gives nothing to order.
    private static let corroboratedRunLength = 3

    /// How many runs must hold up on their own spacing before corroborated
    /// ones are allowed to join them.
    private static let minimumStandAloneRuns = 2

    /// A truss running upstage to downstage. Named apart from a cross-stage
    /// truss because it is a different thing to a user and, unlike one, is
    /// not an LX bar.
    private static let upDownTruss = "Up/Down Truss"

    /// How far past the main body of the rig, as a fraction of its own
    /// half-width, a position has to sit before it counts as a wing.
    private static let wingGapFraction = 0.5

    /// Truss lines the rest of the rig can vouch for.
    ///
    /// Detection otherwise runs per fixture type in isolation, which throws
    /// away the most useful fact about a real rig: a truss usually carries
    /// several types. A type with two lights on a bar cannot establish that
    /// bar on its own — but it does not have to, if another type has a
    /// solid run along the same depth and height.
    ///
    /// **Corroboration always excludes the type being judged.** A line
    /// part-confirmed by the candidate's own fixtures is just the candidate
    /// agreeing with itself; measured, that circularity inflated the number
    /// of corroborated candidates from 78 to 290.
    private struct TrussEvidence {
        private struct Line {
            /// Extent on the two axes perpendicular to the run.
            let lo: (Double, Double)
            let hi: (Double, Double)
            /// Every fixture on this line: which type, and where along it.
            let members: [(spec: String, along: Double)]
        }

        private var byAxis: [[Line]]
        private let pitch: Double
        private let slack: (Double, Double, Double)

        init(fixtures: [Placed], tolerance: AutoIDTolerance) {
            pitch = MVRAutoID.medianNearestNeighbour(fixtures.map(\.point))
            slack = (tolerance.x, tolerance.y, tolerance.z)

            byAxis = (0..<3).map { axis in
                let perpendicular = MVRAutoID.perpendicularAxes(axis)
                return MVRAutoID.runs(fixtures, along: axis, tolerance: tolerance).map { bucket in
                    let first = MVRAutoID.axisKeyPath(perpendicular.0)
                    let second = MVRAutoID.axisKeyPath(perpendicular.1)
                    let along = MVRAutoID.axisKeyPath(axis)
                    let a = bucket.map { $0.point[keyPath: first] }
                    let b = bucket.map { $0.point[keyPath: second] }
                    return Line(
                        lo: (a.min() ?? 0, b.min() ?? 0),
                        hi: (a.max() ?? 0, b.max() ?? 0),
                        members: bucket.map { ($0.fixture.gdtfSpec, $0.point[keyPath: along]) })
                }
            }
        }

        /// True when types *other* than this one hold a believable run along
        /// the line these fixtures sit on, **and** the candidate's fixtures
        /// slot into that run rather than merely sharing its line.
        ///
        /// The second half is what makes this mean something. Asking only
        /// whether a line exists let two floor lights a metre apart get
        /// carved out of their package because some other type happened to
        /// align with them — 103 new groups on the first attempt, mostly
        /// fragments of that kind. The real claim being tested is that this
        /// type's lights and the other type's lights *together* form the
        /// truss's regular spacing, which is exactly why the candidate
        /// looked irregular on its own.
        func corroborates(_ run: [Placed], along axis: Int, excluding spec: String) -> Bool {
            guard !run.isEmpty else { return false }

            let perpendicular = MVRAutoID.perpendicularAxes(axis)
            let first = MVRAutoID.axisKeyPath(perpendicular.0)
            let second = MVRAutoID.axisKeyPath(perpendicular.1)
            let tolerances = [slack.0, slack.1, slack.2]
            let firstSlack = max(tolerances[perpendicular.0], 0.01)
            let secondSlack = max(tolerances[perpendicular.1], 0.01)

            let a = run.map { $0.point[keyPath: first] }
            let b = run.map { $0.point[keyPath: second] }
            guard let aLow = a.min(), let aHigh = a.max(),
                  let bLow = b.min(), let bHigh = b.max() else { return false }

            for line in byAxis[axis] {
                guard aLow >= line.lo.0 - firstSlack, aHigh <= line.hi.0 + firstSlack,
                      bLow >= line.lo.1 - secondSlack, bHigh <= line.hi.1 + secondSlack else { continue }

                let others = line.members.filter { $0.spec != spec }.map(\.along).sorted()
                guard MVRAutoID.isPlausibleSpacing(others, pitch: pitch) else { continue }

                // The candidate must complete that run, not sit beside it.
                let along = MVRAutoID.axisKeyPath(axis)
                let combined = (others + run.map { $0.point[keyPath: along] }).sorted()
                if MVRAutoID.isPlausibleSpacing(combined, pitch: pitch) { return true }
            }
            return false
        }
    }

    /// Re-splits a cluster that proximity clustering has plainly got wrong.
    ///
    /// Single-linkage assumes fixtures on one position are closer to each
    /// other than to the next position. On a box truss rig that is simply
    /// false: measured on CV26, the Color Strike Ms sit 2.94m apart along
    /// their own truss while the nearest fixture on the *neighbouring*
    /// truss is 3.55m away — and one truss's own two fixtures are 23.6m
    /// apart while its neighbour is 6.3m off. There is no threshold that
    /// separates those, at any setting of the spacing slider, so the whole
    /// type chained into one 34-fixture lump spanning the rig.
    ///
    /// What does separate them is that each truss is a straight line at a
    /// constant depth and height. So where a cluster is too thick to be a
    /// run, it is re-cut by collinearity instead of distance.
    ///
    /// Returns nil when the cluster looks fine, or when no axis explains it
    /// well enough to be worth overriding what clustering already decided.
    private static func collinearRuns(
        _ cluster: [Placed],
        within all: [Placed],
        distance: Double,
        tolerance: AutoIDTolerance,
        evidence: TrussEvidence?
    ) -> [[Placed]]? {
        guard cluster.count >= 6 else { return nil }

        func extent(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
        func spans(_ points: [Point]) -> [Double] {
            [extent(points.map(\.x)), extent(points.map(\.y)), extent(points.map(\.z))]
        }

        let mine = spans(cluster.map(\.point))
        let whole = spans(all.map(\.point))
        let sorted = mine.sorted(by: >)
        guard sorted[0] > 0.01 else { return nil }

        // How this type hangs. Used both to judge evenness below and to
        // decide, here, whether the cluster is wider than one line.
        let pitch = medianNearestNeighbour(cluster.map(\.point))

        // Two independent reasons to look at a cluster.
        //
        // A chained lump: thick across its second axis *and* filling the
        // type on at least two axes — the second half is what tells it from
        // a genuinely chunky position. (Vacuously true when the cluster is
        // the whole type, which is right: a type whose entire population
        // chained into one lump is the worst case of all.)
        let filled = zip(mine, whole).filter { $0 > 0.01 && $0 >= $1 * blobSpanFraction }.count
        let isChained = sorted[1] > sorted[0] * runThickness && filled >= blobSpanAxes

        // Or parallel rows: long enough to hold rows, and spread across a
        // whole fixture pitch, so it is more than one line.
        let isParallelRows = pitch > 0.01
            && sorted[1] >= pitch * parallelRowPitchFraction
            && sorted[0] >= pitch * parallelRowMinLength

        guard isChained || isParallelRows else { return nil }

        // Candidates from every axis at once, not the best single axis. A
        // rig commonly carries both cross-stage bars and trusses running
        // upstage to downstage, and picking one winning axis found the
        // first and lost the second.
        var candidates: [(run: [Placed], axis: Int)] = []
        for axis in 0..<3 {
            for bucket in runs(cluster, along: axis, tolerance: tolerance) {
                // Cut at the real breaks first. Bucketing only separates
                // *parallel* lines; it says nothing about a gap along one.
                // The upstage Sceptron line on one arena rig is three
                // trusses end to end with 4.2m between them and 0.9m
                // between fixtures — as a whole it failed the evenness
                // test and was thrown away, when it should have been cut.
                for piece in segments(of: bucket, along: axis)
                where isPlausibleRun(piece, along: axis, pitch: pitch, evidence: evidence) {
                    candidates.append((piece, axis))
                }
            }
        }

        // Longest first, so a real truss claims its fixtures before a
        // shorter line that happens to cross it. Ties go to the run that
        // stands up on its own spacing, ahead of one leaning on evidence.
        candidates.sort {
            if $0.run.count != $1.run.count { return $0.run.count > $1.run.count }
            let a = isPlausibleRun($0.run, along: $0.axis, pitch: pitch, evidence: nil)
            let b = isPlausibleRun($1.run, along: $1.axis, pitch: pitch, evidence: nil)
            return a && !b
        }

        var claimed: Set<String> = []
        var accepted: [[Placed]] = []
        var standAlone = 0
        for candidate in candidates {
            let free = candidate.run.filter { !claimed.contains($0.fixture.id) }
            // Re-checked after claiming: what's left of a crossed run may
            // no longer be a run at all.
            guard isPlausibleRun(free, along: candidate.axis, pitch: pitch, evidence: evidence) else { continue }
            if isPlausibleRun(free, along: candidate.axis, pitch: pitch, evidence: nil) { standAlone += 1 }
            claimed.formUnion(free.map(\.fixture.id))
            accepted.append(free)
        }

        // Corroboration may only *supplement* a decomposition, never
        // constitute one. Without this, a raked rig whose every depth
        // carries a symmetric pair got rebuilt entirely out of corroborated
        // pairs — one real file went from 21 groups to 56, re-creating the
        // fragmentation the plausibility test exists to prevent.
        guard standAlone >= minimumStandAloneRuns, accepted.count >= 2 else { return nil }

        // Whatever isn't on a recognisable position goes back to proximity
        // clustering rather than being emitted as debris — whole types are
        // rarely all truss, and a scatter of floor fixtures around two real
        // trusses should still group the way it always did.
        let leftovers = cluster.filter { !claimed.contains($0.fixture.id) }
        return accepted + clusters(leftovers, distance: distance).flatMap { sub -> [[Placed]] in
            // What's left can chain all over again. Bounded by the strictly
            // smaller size, so this can only recurse a finite number of times.
            guard sub.count < cluster.count else { return [sub] }
            return collinearRuns(
                sub, within: all, distance: distance,
                tolerance: tolerance, evidence: evidence) ?? [sub]
        }
    }

    /// Cuts a line of fixtures wherever the spacing plainly breaks.
    ///
    /// The threshold is the run's own median gap, by the same factor that
    /// defines evenness — so a truss missing a fixture stays whole, while a
    /// gap several times the spacing is read as the end of one truss and
    /// the start of the next.
    private static func segments(of run: [Placed], along axis: Int) -> [[Placed]] {
        guard run.count >= minimumRunLength else { return [run] }

        let keyPath = axisKeyPath(axis)
        let sorted = run.sorted { $0.point[keyPath: keyPath] < $1.point[keyPath: keyPath] }
        let gaps = zip(sorted, sorted.dropFirst()).map {
            $1.point[keyPath: keyPath] - $0.point[keyPath: keyPath]
        }
        guard !gaps.isEmpty else { return [run] }

        let median = gaps.sorted()[gaps.count / 2]
        guard median > 0 else { return [run] }
        let limit = median * runEvenness

        var pieces: [[Placed]] = []
        var current: [Placed] = [sorted[0]]
        for (index, gap) in gaps.enumerated() {
            if gap > limit {
                pieces.append(current)
                current = []
            }
            current.append(sorted[index + 1])
        }
        pieces.append(current)
        return pieces
    }

    /// Whether a candidate run looks like fixtures hung along one position.
    ///
    /// `evidence` gives a run that fails on its own a second chance: if
    /// other types hold a believable run along the same line, this is that
    /// truss too. Two lights on a shared bar are the common case — and the
    /// spacing test is the *wrong* test for them, because a type's fixtures
    /// on a mixed truss are irregular precisely where another type's
    /// fixtures fill the gaps.
    private static func isPlausibleRun(
        _ run: [Placed],
        along axis: Int,
        pitch: Double,
        evidence: TrussEvidence?
    ) -> Bool {
        let keyPath = axisKeyPath(axis)
        let coordinates = run.map { $0.point[keyPath: keyPath] }.sorted()

        if run.count >= minimumRunLength, isPlausibleSpacing(coordinates, pitch: pitch) { return true }

        // Corroborated: still needs two fixtures to be a run at all, but
        // nothing about its own spacing, which the other types settle.
        guard run.count >= corroboratedRunLength,
              let evidence,
              let spec = run.first?.fixture.gdtfSpec else { return false }
        return evidence.corroborates(run, along: axis, excluding: spec)
    }

    /// Regularly spaced, and spaced like the rig hangs — not spanning it in
    /// two hops.
    private static func isPlausibleSpacing(_ coordinates: [Double], pitch: Double) -> Bool {
        guard coordinates.count >= minimumRunLength else { return false }
        let gaps = zip(coordinates, coordinates.dropFirst()).map { $1 - $0 }
        guard let widest = gaps.max(), widest > 0 else { return false }
        let median = gaps.sorted()[gaps.count / 2]
        guard median > 0 else { return false }
        return widest <= median * runEvenness && widest <= pitch * runPitchFactor
    }

    private static func axisKeyPath(_ axis: Int) -> KeyPath<Point, Double> {
        switch axis {
        case 0: return \.x
        case 1: return \.y
        default: return \.z
        }
    }

    /// The two axes a run of this direction is pinned by.
    private static func perpendicularAxes(_ axis: Int) -> (Int, Int) {
        switch axis {
        case 0: return (1, 2)
        case 1: return (0, 2)
        default: return (0, 1)
        }
    }

    private static func medianNearestNeighbour(_ points: [Point]) -> Double {
        guard points.count >= 2 else { return 1 }
        var nearest: [Double] = []
        for (index, point) in points.enumerated() {
            var best = Double.greatestFiniteMagnitude
            for (other, candidate) in points.enumerated() where other != index {
                best = min(best, point.distance(to: candidate))
            }
            if best.isFinite { nearest.append(best) }
        }
        guard !nearest.isEmpty else { return 1 }
        nearest.sort()
        return nearest[nearest.count / 2]
    }

    /// Buckets a cluster into lines running along one axis: fixtures share
    /// a line when they match on both of the *other* two axes.
    private static func runs(_ cluster: [Placed], along axis: Int, tolerance: AutoIDTolerance) -> [[Placed]] {
        let keys: [(KeyPath<Point, Double>, Double)]
        switch axis {
        case 0: keys = [(\.y, tolerance.y), (\.z, tolerance.z)]
        case 1: keys = [(\.x, tolerance.x), (\.z, tolerance.z)]
        default: keys = [(\.x, tolerance.x), (\.y, tolerance.y)]
        }

        var buckets = [cluster]
        for (keyPath, slack) in keys {
            var next: [[Placed]] = []
            for bucket in buckets {
                let sorted = bucket.sorted { $0.point[keyPath: keyPath] < $1.point[keyPath: keyPath] }
                var current: [Placed] = []
                for placed in sorted {
                    if let last = current.last,
                       placed.point[keyPath: keyPath] - last.point[keyPath: keyPath] > max(slack, 0.01) {
                        next.append(current)
                        current = []
                    }
                    current.append(placed)
                }
                if !current.isEmpty { next.append(current) }
            }
            buckets = next
        }
        return buckets
    }

    // MARK: - Ordering

    /// Groups the clusters into depth bands, one band per bar.
    ///
    /// Single-linkage along depth alone — a gap wider than the tolerance
    /// starts a new bar — which is exactly how `lxNumbers` decides what
    /// counts as one bar. Shared so a type's rows read in the same order as
    /// the LX numbers written on them.
    private static func depthBands(_ clusters: [[Placed]]) -> [Set<String>: Int] {
        let depths = clusters.map { cluster -> (key: Set<String>, depth: Double) in
            let ys = cluster.map(\.point.y)
            return (Set(cluster.map(\.fixture.id)), ys.reduce(0, +) / Double(max(ys.count, 1)))
        }

        var result: [Set<String>: Int] = [:]
        var band = 0
        var previous: Double?
        for entry in depths.sorted(by: { $0.depth < $1.depth }) {
            if let previous, entry.depth - previous > lxBandTolerance { band += 1 }
            result[entry.key] = band
            previous = entry.depth
        }
        return result
    }

    private static func orderedClusters(
        _ placed: [Placed],
        distance: Double,
        manualGroups: [Set<String>],
        groupOrdering: [Set<String>: AutoIDOrderStrategy],
        tolerance: AutoIDTolerance,
        groupTolerance: [Set<String>: AutoIDTolerance],
        groupReversed: Set<Set<String>>,
        groupSpacing: [Set<String>: Double],
        repairChains: Bool,
        evidence: TrussEvidence?
    ) -> [[Placed]] {
        // Hand-fixed groups are taken as given; only what's left over is
        // clustered, so a manual split can't be silently re-merged by the
        // automatic pass running over the top of it.
        var claimed: Set<String> = []
        var fixed: [[Placed]] = []
        for ids in manualGroups {
            let members = placed.filter { ids.contains($0.fixture.id) && !claimed.contains($0.fixture.id) }
            guard !members.isEmpty else { continue }
            claimed.formUnion(members.map(\.fixture.id))
            fixed.append(members)
        }
        let remaining = placed.filter { !claimed.contains($0.fixture.id) }

        // Only automatic clusters are repaired — a hand-made group is the
        // user's explicit answer and is never second-guessed.
        let automatic = clusters(remaining, distance: distance).flatMap { cluster -> [[Placed]] in
            guard repairChains else { return [cluster] }
            return collinearRuns(
                cluster, within: placed, distance: distance,
                tolerance: tolerance, evidence: evidence) ?? [cluster]
        }

        // A spacing set for one blob is applied to the groups as they
        // finally stand, not to the raw clusters underneath.
        //
        // That is what the user picked it from — the row in the list — and
        // matching earlier silently did nothing whenever the group had come
        // out of the collinear repair rather than straight from proximity.
        // Stable despite re-splitting changing the membership, because
        // everything above is deterministic: the same blob reforms each
        // recompute and the key matches again.
        let divided = (fixed + automatic).flatMap { cluster -> [[Placed]] in
            guard let spacing = groupSpacing[Set(cluster.map(\.fixture.id))] else { return [cluster] }
            return clusters(cluster, distance: max(spacing, 0.01))
        }

        let grouped = divided.map { cluster in
            let key = Set(cluster.map(\.fixture.id))
            let slack = groupTolerance[key] ?? tolerance
            let ordered = order(
                within: cluster,
                strategy: groupOrdering[key] ?? suggestedStrategy(for: cluster, tolerance: slack),
                tolerance: slack)
            // Applied last, over whatever the strategy produced, so it
            // means "the other way round" for every shape — including
            // `.aroundShape`, where reversing the path is exactly what
            // walking the U from the far leg would give.
            return groupReversed.contains(key) ? ordered.reversed() : ordered
        }

        // Groups run downstage to upstage. Depth is banded rather than
        // compared outright, so two trusses at the same depth — wings left
        // and right, say — order left-to-right instead of by millimetre
        // differences in their centroids.
        //
        // Banded at the same tolerance the LX numbering uses, and by the
        // same chaining, so the two cannot disagree. They did: the band was
        // the *grouping* distance, which is about how far apart fixtures on
        // one bar sit, not how far apart two bars must be to count as
        // different depths. At a typical 3.75 m that put bars 3 m apart in
        // one band and then ordered them left-to-right, so a type listed
        // LX2, LX5, LX3, LX6 — right numbers, wrong order.
        let bands = depthBands(grouped)
        func depthBand(_ cluster: [Placed]) -> Int { bands[Set(cluster.map(\.fixture.id))] ?? 0 }
        func leftEdge(_ cluster: [Placed]) -> Double {
            cluster.map(\.point.x).min() ?? 0
        }

        return grouped.sorted {
            let (a, b) = (depthBand($0), depthBand($1))
            if a != b { return a < b }
            return leftEdge($0) < leftEdge($1)
        }
    }

    /// The strategy to use when the user hasn't chosen one.
    ///
    /// A straight run only has one sensible answer, so it takes the cheap
    /// path. A shape that isn't straight — a U, an arc, a hollow square —
    /// has several, and the app used to shrug and hand back left-to-right,
    /// which on a closed square walks back and forth across the middle.
    ///
    /// Judged by **total path length**: the numbering that walks the least
    /// distance is the one that follows the shape rather than fighting it.
    /// The same measure that showed `.aroundShape` beating `.leftToRight`
    /// 37.4m to 47.9m on a real U. Ties keep left-to-right, so nothing
    /// changes for the ordinary case.
    private static func suggestedStrategy(
        for cluster: [Placed],
        tolerance: AutoIDTolerance
    ) -> AutoIDOrderStrategy {
        guard cluster.count >= 4, isAmbiguous(cluster) else { return .leftToRight }

        var best: (strategy: AutoIDOrderStrategy, length: Double) = (.leftToRight, .infinity)
        for strategy in AutoIDOrderStrategy.allCases {
            let ordered = order(within: cluster, strategy: strategy, tolerance: tolerance)
            let length = pathLength(ordered)
            // Strictly shorter, so an equal-length alternative never
            // displaces the order the list is already sorted by.
            if length < best.length - 0.001 { best = (strategy, length) }
        }
        return best.strategy
    }

    private static func pathLength(_ ordered: [Placed]) -> Double {
        guard ordered.count > 1 else { return 0 }
        return zip(ordered, ordered.dropFirst()).reduce(0) { $0 + $1.0.point.distance(to: $1.1.point) }
    }

    private static func order(
        within cluster: [Placed],
        strategy: AutoIDOrderStrategy,
        tolerance: AutoIDTolerance
    ) -> [Placed] {
        switch strategy {
        case .leftToRight: return orderLeftToRight(cluster, tolerance: tolerance)
        case .topToBottom: return orderTopToBottom(cluster, tolerance: tolerance)
        case .zigZagRows: return orderRows(cluster, tolerance: tolerance, alternating: true)
        case .rowsSameDirection: return orderRows(cluster, tolerance: tolerance, alternating: false)
        case .aroundShape: return orderAroundShape(cluster, tolerance: tolerance)
        case .columnsTopToBottom: return orderColumns(cluster, tolerance: tolerance)
        }
    }

    /// Left to right, then down the group for anything sharing a column.
    ///
    /// The secondary axis follows the geometry rather than always being
    /// height: a hanging ladder is separated by height, but a floor package
    /// laid out flat is separated by depth, and sorting that by height would
    /// barely order it at all.
    /// Breaks a tie by something the file actually says.
    ///
    /// `fixture.id` looks like the obvious key and is the wrong one: it is
    /// a fresh UUID minted at load, so it is stable within a session and
    /// different the next time the same file is opened. Coincident
    /// fixtures — a pair hung on the same point, or any two inside the
    /// tolerance on every axis — were being ordered by it, which meant
    /// opening a show twice could hand those fixtures different IDs.
    private static func fileOrder(_ first: Placed, _ second: Placed) -> Bool {
        (first.fixture.name, first.fixture.originalUUID)
            < (second.fixture.name, second.fixture.originalUUID)
    }

    private static func orderLeftToRight(_ cluster: [Placed], tolerance: AutoIDTolerance) -> [Placed] {
        let depthFirst = usesDepthAsSecondaryAxis(cluster)
        return cluster.sorted { first, second in
            if abs(first.point.x - second.point.x) > tolerance.x {
                return first.point.x < second.point.x
            }
            if depthFirst {
                if abs(first.point.y - second.point.y) > tolerance.y { return first.point.y < second.point.y }
                if abs(first.point.z - second.point.z) > tolerance.z { return first.point.z > second.point.z }
            } else {
                if abs(first.point.z - second.point.z) > tolerance.z { return first.point.z > second.point.z }
                if abs(first.point.y - second.point.y) > tolerance.y { return first.point.y < second.point.y }
            }
            // Fully coincident fixtures still need a stable order.
            return fileOrder(first, second)
        }
    }

    private static func orderTopToBottom(_ cluster: [Placed], tolerance: AutoIDTolerance) -> [Placed] {
        cluster.sorted { first, second in
            if abs(first.point.z - second.point.z) > tolerance.z {
                return first.point.z > second.point.z
            }
            if abs(first.point.x - second.point.x) > tolerance.x {
                return first.point.x < second.point.x
            }
            if abs(first.point.y - second.point.y) > tolerance.y {
                return first.point.y < second.point.y
            }
            return fileOrder(first, second)
        }
    }

    /// True when the group is spread more through depth than height, i.e.
    /// laid out on the floor rather than hung.
    private static func usesDepthAsSecondaryAxis(_ cluster: [Placed]) -> Bool {
        let ys = cluster.map(\.point.y), zs = cluster.map(\.point.z)
        let depth = (ys.max() ?? 0) - (ys.min() ?? 0)
        let height = (zs.max() ?? 0) - (zs.min() ?? 0)
        return depth > height
    }

    /// Rows stepping through the group, each running opposite to the one
    /// above or in front of it.
    ///
    /// Rows band along whichever of height or depth the group is actually
    /// spread through, not always height: this rig's floor package varies
    /// 10.7m in depth but only 0.38m in height, so banding by height gave
    /// two rows and ordered almost nothing. Fixtures within the tolerance of
    /// each other count as the same row, so a row that sags slightly — or a
    /// leg rigged a few centimetres out — still reads as one.
    /// Rows banded across the group's secondary axis, each row read along
    /// X. `alternating` is the difference between a zig-zag and a carriage
    /// return: with it off, every row starts from the same side.
    /// Each vertical line in full, top to bottom, then the next line.
    ///
    /// The transpose of `orderRows`, and it reuses the same row banding so
    /// the two cannot disagree about what a row is. Columns fall out of the
    /// rows: the first fixture of every row is column one, the second of
    /// every row is column two.
    ///
    /// Deriving columns from the rows rather than from horizontal position
    /// is what makes this work on a real tower. Banding horizontally needs
    /// a distance to call "the same column", and the only one available is
    /// the ordering tolerance — 0.2 m by default, which is about the
    /// spacing of the pair itself. A tower 0.2 m wide then reads as one
    /// column and numbers straight back down in pairs, which is the thing
    /// this mode exists to avoid. Two fixtures at the same height cannot be
    /// in one column, and that needs no distance at all.
    private static func orderColumns(_ cluster: [Placed], tolerance: AutoIDTolerance) -> [Placed] {
        guard cluster.count > 1 else { return cluster }

        let rows = rowBands(cluster, tolerance: tolerance)
        let widest = rows.map(\.count).max() ?? 0

        // A row short of fixtures simply has no entry in the later columns
        // — a tower missing one of a pair keeps the rest in line rather
        // than shunting everything below it across.
        return (0..<widest).flatMap { index in
            rows.compactMap { $0.indices.contains(index) ? $0[index] : nil }
        }
    }

    /// The group split into rows and each row sorted across the stage.
    ///
    /// Rows run top-down when the group is hung and front-to-back when it
    /// is on the floor, which is the same question `usesDepthAsSecondaryAxis`
    /// answers for the other strategies.
    private static func rowBands(_ cluster: [Placed], tolerance: AutoIDTolerance) -> [[Placed]] {
        let byDepth = usesDepthAsSecondaryAxis(cluster)
        let axis: (Placed) -> Double = byDepth ? { $0.point.y } : { $0.point.z }
        let band = max(byDepth ? tolerance.y : tolerance.z, 0.01)
        let ordered = cluster.sorted { byDepth ? axis($0) < axis($1) : axis($0) > axis($1) }

        var rows: [[Placed]] = []
        for placed in ordered {
            if let reference = rows.last?.last, abs(axis(reference) - axis(placed)) <= band {
                rows[rows.count - 1].append(placed)
            } else {
                rows.append([placed])
            }
        }
        return rows.map { $0.sorted(by: acrossThenDeep) }
    }

    /// Across the stage, then upstage, then down — with a tie broken by
    /// what the file says, never by the per-load `fixture.id`.
    private static func acrossThenDeep(_ first: Placed, _ second: Placed) -> Bool {
        if first.point.x != second.point.x { return first.point.x < second.point.x }
        if first.point.y != second.point.y { return first.point.y < second.point.y }
        if first.point.z != second.point.z { return first.point.z > second.point.z }
        return fileOrder(first, second)
    }

    private static func orderRows(
        _ cluster: [Placed],
        tolerance: AutoIDTolerance,
        alternating: Bool
    ) -> [Placed] {
        guard cluster.count > 1 else { return cluster }

        return rowBands(cluster, tolerance: tolerance).enumerated().flatMap { index, row -> [Placed] in
            guard alternating else { return row }
            return index.isMultiple(of: 2) ? row : row.reversed()
        }
    }

    /// Walks the group from one end to the other, always stepping to the
    /// nearest fixture not yet used.
    ///
    /// This is what makes a U work: starting at one leg tip it runs down
    /// that leg, along the back and up the far leg, instead of sweeping
    /// left-to-right and jumping back and forth between the two legs. The
    /// start is the end of the group's longest span — for a U, one of the
    /// two tips — choosing the left-hand one so numbering still begins
    /// where someone would expect.
    private static func orderAroundShape(_ cluster: [Placed], tolerance: AutoIDTolerance) -> [Placed] {
        guard cluster.count > 2 else { return orderLeftToRight(cluster, tolerance: tolerance) }

        var best = (first: 0, second: 1, distance: -1.0)
        for i in 0..<cluster.count {
            for j in (i + 1)..<cluster.count {
                let distance = Double(cluster[i].point.distance(to: cluster[j].point))
                if distance > best.distance { best = (i, j, distance) }
            }
        }

        let candidates = [cluster[best.first], cluster[best.second]]
        let start = candidates.min {
            abs($0.point.x - $1.point.x) > tolerance.x
                ? $0.point.x < $1.point.x
                : $0.point.z > $1.point.z
        } ?? cluster[0]

        var remaining = cluster
        remaining.removeAll { $0.fixture.id == start.fixture.id }
        var ordered = [start]

        while !remaining.isEmpty {
            let current = ordered[ordered.count - 1].point
            var nearest = 0
            var nearestDistance = Double.greatestFiniteMagnitude
            for (index, candidate) in remaining.enumerated() {
                let distance = Double(current.distance(to: candidate.point))
                if distance < nearestDistance { nearestDistance = distance; nearest = index }
            }
            ordered.append(remaining.remove(at: nearest))
        }
        return ordered
    }

    // MARK: - Shape

    /// How far a group departs from a straight line, as the widest sideways
    /// deviation from its own long axis divided by the length of that axis.
    ///
    /// Near zero for a truss; large for a U, an arc or a block. Used to
    /// decide when the numbering order is a real choice rather than
    /// something to assume.
    static func straightness(fixtures: [MVRFixture]) -> Double {
        let points = split(fixtures).placed.map(\.point)
        guard points.count > 2 else { return 0 }

        var ends = (first: 0, second: 1, distance: -1.0)
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let distance = Double(points[i].distance(to: points[j]))
                if distance > ends.distance { ends = (i, j, distance) }
            }
        }
        guard ends.distance > 0.001 else { return 0 }

        let start = points[ends.first], end = points[ends.second]
        let axisX = end.x - start.x, axisY = end.y - start.y, axisZ = end.z - start.z
        let axisLength = ends.distance

        var widest = 0.0
        for point in points {
            let offsetX = point.x - start.x, offsetY = point.y - start.y, offsetZ = point.z - start.z
            // |offset x axis| / |axis| is the perpendicular distance from the
            // line through the two most distant fixtures.
            let crossX = offsetY * axisZ - offsetZ * axisY
            let crossY = offsetZ * axisX - offsetX * axisZ
            let crossZ = offsetX * axisY - offsetY * axisX
            let magnitude = (crossX * crossX + crossY * crossY + crossZ * crossZ).squareRoot()
            widest = max(widest, magnitude / axisLength)
        }
        return widest / axisLength
    }

    /// True when a group bends far enough off its own axis that left-to-right
    /// stops being an obvious answer.
    static func isAmbiguousShape(fixtures: [MVRFixture]) -> Bool {
        straightness(fixtures: fixtures) > 0.12
    }

    /// One group's fixture ids in the order a given strategy would number
    /// them. Exposed so the choice can be checked against the alternatives.
    static func orderedIDs(
        fixtures: [MVRFixture],
        strategy: AutoIDOrderStrategy,
        tolerance: AutoIDTolerance
    ) -> [String] {
        order(within: split(fixtures).placed, strategy: strategy, tolerance: tolerance)
            .map(\.fixture.id)
    }

    /// The strategy this group would be numbered by if left alone.
    static func suggestedStrategy(
        fixtures: [MVRFixture],
        tolerance: AutoIDTolerance
    ) -> AutoIDOrderStrategy {
        suggestedStrategy(for: split(fixtures).placed, tolerance: tolerance)
    }

    private static func isAmbiguous(_ cluster: [Placed]) -> Bool {
        isAmbiguousShape(fixtures: cluster.map(\.fixture))
    }

    /// Applies a hand-set group order, leaving anything unrecognised in its
    /// automatic place at the end.
    private static func reordered(_ clusters: [[Placed]], following wanted: [Set<String>]) -> [[Placed]] {
        var rank: [Set<String>: Int] = [:]
        for (index, key) in wanted.enumerated() { rank[key] = index }

        return clusters.enumerated().sorted { first, second in
            let firstRank = rank[Set(first.element.map(\.fixture.id))] ?? Int.max
            let secondRank = rank[Set(second.element.map(\.fixture.id))] ?? Int.max
            if firstRank != secondRank { return firstRank < secondRank }
            // Ties are groups the order doesn't mention; keep them as found.
            return first.offset < second.offset
        }.map(\.element)
    }

    // MARK: - Manual corrections

    /// Splits a group in two at its largest spatial gap.
    ///
    /// Aimed at the common failure: a run that clustering swallowed whole
    /// because its fixtures are evenly spaced but the run itself is really
    /// two trusses — one measured file has 30 ROXX Clusters landing in a
    /// single 18m group. Members are sorted along whichever axis they're
    /// most spread over and cut at the biggest step, which is where the eye
    /// would put the boundary too. Returns nil if there's no meaningful gap.
    static func splitAtLargestGap(fixtures: [MVRFixture]) -> (Set<String>, Set<String>)? {
        let placed = split(fixtures).placed
        guard placed.count >= 2 else { return nil }

        let xs = placed.map(\.point.x), ys = placed.map(\.point.y), zs = placed.map(\.point.z)
        let spans = [
            (span: (xs.max() ?? 0) - (xs.min() ?? 0), axis: { (p: Point) in p.x }),
            (span: (ys.max() ?? 0) - (ys.min() ?? 0), axis: { (p: Point) in p.y }),
            (span: (zs.max() ?? 0) - (zs.min() ?? 0), axis: { (p: Point) in p.z }),
        ]
        guard let longest = spans.max(by: { $0.span < $1.span }), longest.span > 0 else { return nil }

        let sorted = placed.sorted { longest.axis($0.point) < longest.axis($1.point) }
        var cut = 0
        var widest = 0.0
        for index in 1..<sorted.count {
            let gap = longest.axis(sorted[index].point) - longest.axis(sorted[index - 1].point)
            if gap > widest { widest = gap; cut = index }
        }
        guard cut > 0 else { return nil }

        return (
            Set(sorted[..<cut].map(\.fixture.id)),
            Set(sorted[cut...].map(\.fixture.id))
        )
    }

    // MARK: - Numbering

    /// Smallest `k * blockSize + 1` that is at least `cursor`, so blocks
    /// read as 1001, 2001, 2301 rather than starting mid-hundred.
    /// One type's clusters, sized but not yet numbered.
    private struct PendingType {
        let spec: String
        let clusters: [[Placed]]
        let trailing: [MVRFixture]
        let fixtureCount: Int
        /// How many IDs the type actually occupies. The same as
        /// `fixtureCount` until gaps are switched on, after which a type
        /// can span several times its own size and would otherwise be
        /// handed a block it doesn't fit in.
        let idSpan: Int
        let groupingDistance: Double
    }

    private struct Placement {
        let type: PendingType
        let start: Int
        let blockSize: Int
    }

    /// Hands each type a block, working around any the user has pinned.
    ///
    /// Pinning a start is a statement about where that type belongs, so it
    /// is honoured exactly and everything else flows around it — which is
    /// what "move the other IDs" has to mean in practice. Two pinned blocks
    /// that overlap each other are the user's own conflict and are left to
    /// collide, where the collision warning will report them.
    private static func allocate(_ types: [PendingType], options: AutoIDOptions) -> [Placement] {
        func blockSize(_ count: Int) -> Int { count <= 100 ? 100 : 1000 }

        // Reserved first, so a flowing type can be steered clear of them.
        var reserved: [ClosedRange<Int>] = []
        for type in types {
            guard let pinned = options.typeStartingID[type.spec] else { continue }
            let start = max(1, pinned)
            reserved.append(start...(start + max(type.idSpan, 1) - 1))
        }

        var placements: [Placement] = []
        var cursor = max(1, options.startingID)

        for type in types {
            let size = blockSize(type.idSpan)

            if let pinned = options.typeStartingID[type.spec] {
                let start = max(1, pinned)
                placements.append(Placement(type: type, start: start, blockSize: size))
                // Numbering carries on after a pinned block when it lies
                // ahead, so the run keeps reading in order.
                cursor = max(cursor, start + max(type.idSpan, 1))
                continue
            }

            var start = blockStart(atLeast: cursor, blockSize: size)
            let span = max(type.idSpan, 1)
            while let clash = reserved.first(where: { $0.overlaps(start...(start + span - 1)) }) {
                start = blockStart(atLeast: clash.upperBound + 1, blockSize: size)
            }
            placements.append(Placement(type: type, start: start, blockSize: size))
            cursor = start + span
        }
        return placements
    }

    /// How many IDs a type's groups take up, gaps included.
    ///
    /// Walks the same shape as the numbering loop rather than deriving a
    /// formula, so the two cannot drift apart. Group starts the user has
    /// pinned are ignored here exactly as they were before gaps existed:
    /// a pin can land anywhere, and two pins that collide are the user's
    /// own conflict for the collision warning to report.
    private static func numberedSpan(
        groupSizes: [Int], gaps: AutoIDGaps
    ) -> Int {
        let sizes = groupSizes.filter { $0 > 0 }
        guard !sizes.isEmpty else { return 0 }
        let step = gaps.fixtureStep
        var span = 0
        for (index, count) in sizes.enumerated() {
            if index > 0 { span += gaps.groupSpacing }
            span += (count - 1) * step + 1
        }
        return span
    }

    private static func blockStart(atLeast cursor: Int, blockSize: Int) -> Int {
        if cursor % blockSize == 1 { return cursor }
        return ((cursor - 1) / blockSize + 1) * blockSize + 1
    }

    /// Proposed IDs that clash — either with each other, or with a fixture
    /// of an excluded type, which keeps whatever ID it already had.
    private static func collisions(
        in assignments: [AutoIDPlan.Assignment],
        allFixtures: [MVRFixture],
        options: AutoIDOptions
    ) -> [Int] {
        let retained = Set(allFixtures
            .filter { !options.includedTypes.contains($0.gdtfSpec) }
            .compactMap(\.currentFixtureID))

        var seen: Set<Int> = []
        var clashing: Set<Int> = []
        for assignment in assignments {
            if !seen.insert(assignment.newID).inserted { clashing.insert(assignment.newID) }
            if retained.contains(assignment.newID) { clashing.insert(assignment.newID) }
        }
        return clashing.sorted()
    }
}
