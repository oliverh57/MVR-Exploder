import Foundation

/// A whole Auto ID session, in a form that survives a round trip through
/// the file.
///
/// Everything the user corrects by hand — merges, splits, orders, names,
/// tolerances, pinned IDs — is keyed by *exact group membership*, and the
/// members are fixtures. That is why none of it could be saved before:
/// `MVRFixture.id` is a fresh `UUID()` minted at load, so a key written on
/// Monday matches nothing on Tuesday. Here the keys are MVR uuids, which
/// are the file's own identity, and `mappingKeys` moves between the two.
///
/// Groups whose members have gone — deleted, or re-specced — simply drop
/// out on the way back in, and the override lapses. That is already how
/// these keys behave inside a session when a group is merged or split, so
/// a file that has been edited elsewhere loses exactly the corrections
/// that no longer describe anything, and keeps the rest.
struct AutoIDStoredSession: Codable, Equatable {
    /// One membership-keyed entry. Written as a list rather than a JSON
    /// object because the key is a set of uuids, not a string.
    struct Entry<Value: Codable & Equatable>: Codable, Equatable {
        var members: [String]
        var value: Value
    }

    var startingID: Int = 1001
    var gaps = AutoIDGaps()
    var tolerance = AutoIDTolerance.default
    var typeOrder: [String] = []
    var includedTypes: [String] = []

    /// Keyed by GDTF spec, so no remapping is needed.
    var typeStartingID: [String: Int] = [:]
    var customGroupingDistance: [String: Double] = [:]
    var mergedTypes: [[String]] = []
    /// Family suggestions turned down, so re-opening doesn't ask again.
    var dismissedMerges: [[String]] = []

    /// Keyed by fixture membership; remapped in and out.
    var manualGroups: [[String]] = []
    var groupReversed: [[String]] = []
    var acknowledged: [[String]] = []
    var groupOrdering: [Entry<String>] = []
    var groupNames: [Entry<String>] = []
    var groupTolerance: [Entry<AutoIDTolerance>] = []
    var groupStartingID: [Entry<Int>] = []
    var groupSpacing: [Entry<Double>] = []
    /// Hand-sorted group order, per spec, each group by its membership.
    var groupOrder: [String: [[String]]] = [:]

    /// True when there is anything worth restoring, so an untouched file
    /// doesn't announce a session that would change nothing.
    var isEmpty: Bool { self == AutoIDStoredSession() }

    // MARK: - Key mapping

    /// Rewrites every fixture key through `transform`, dropping members it
    /// has no answer for.
    ///
    /// Used in both directions: fixture id → MVR uuid on the way out,
    /// uuid → fixture id on the way in. One function rather than two, so
    /// the two halves cannot fall out of step as fields are added.
    func mappingKeys(_ transform: (String) -> String?) -> AutoIDStoredSession {
        func members(_ ids: [String]) -> [String]? {
            let mapped = ids.compactMap(transform)
            // A group that lost members is no longer the group the user
            // corrected, so its correction lapses rather than being
            // silently applied to a subset.
            guard mapped.count == ids.count else { return nil }
            return mapped.sorted()
        }
        // Sorted, because these are sets of groups and the order they
        // happen to be in is not information — leaving it alone made a
        // mapped session compare unequal to the one it came from.
        func unordered(_ list: [[String]]) -> [[String]] {
            list.compactMap(members).sorted { $0.lexicographicallyPrecedes($1) }
        }
        /// The exception: `groupOrder` *is* an order — the one the user
        /// dragged the groups into — so only its members are rewritten.
        func ordered(_ list: [[String]]) -> [[String]] { list.compactMap(members) }
        func entries<V>(_ list: [Entry<V>]) -> [Entry<V>] {
            list.compactMap { entry in
                members(entry.members).map { Entry(members: $0, value: entry.value) }
            }
            .sorted { $0.members.lexicographicallyPrecedes($1.members) }
        }

        var result = self
        result.manualGroups = unordered(manualGroups)
        result.groupReversed = unordered(groupReversed)
        result.acknowledged = unordered(acknowledged)
        result.groupOrdering = entries(groupOrdering)
        result.groupNames = entries(groupNames)
        result.groupTolerance = entries(groupTolerance)
        result.groupStartingID = entries(groupStartingID)
        result.groupSpacing = entries(groupSpacing)
        result.groupOrder = groupOrder.mapValues(ordered).filter { !$0.value.isEmpty }
        return result
    }

    /// Rewrites every GDTF spec key through `transform`.
    ///
    /// Needed because exporting can rename a spec: a fixture whose .gdtf is
    /// missing from the archive gets repointed at a generated dummy, and on
    /// the common "won't import elsewhere" file that is most of the types.
    /// Written with the names the exported file will actually carry, the
    /// per-type settings survive; without this they matched nothing on the
    /// way back in.
    func mappingSpecs(_ transform: (String) -> String) -> AutoIDStoredSession {
        var result = self
        result.typeOrder = typeOrder.map(transform)
        result.includedTypes = includedTypes.map(transform).sorted()
        result.typeStartingID = remapped(typeStartingID, transform)
        result.customGroupingDistance = remapped(customGroupingDistance, transform)
        result.mergedTypes = mergedTypes
            .map { $0.map(transform).sorted() }
            .sorted { $0.lexicographicallyPrecedes($1) }
        result.dismissedMerges = dismissedMerges
            .map { $0.map(transform).sorted() }
            .sorted { $0.lexicographicallyPrecedes($1) }
        result.groupOrder = remapped(groupOrder, transform)
        return result
    }

    /// Two specs can rename onto one dummy — several fixtures sharing a
    /// missing GDTF collapse to a single placeholder — so a collision keeps
    /// the first, matching how the rest of the session treats a key that no
    /// longer describes what it used to.
    private func remapped<Value>(
        _ dictionary: [String: Value], _ transform: (String) -> String
    ) -> [String: Value] {
        Dictionary(dictionary.map { (transform($0.key), $0.value) },
                   uniquingKeysWith: { first, _ in first })
    }

    // MARK: - JSON

    /// Sorted keys, so exporting the same session twice produces the same
    /// bytes — a file that hasn't changed shouldn't look changed.
    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decoded(from text: String) -> AutoIDStoredSession? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AutoIDStoredSession.self, from: data)
    }
}

// MARK: - Dictionary conversion

extension AutoIDStoredSession {
    /// `[Set<String>: Value]` is what the session actually works in; the
    /// entry list is only how it travels.
    static func dictionary<Value>(from entries: [Entry<Value>]) -> [Set<String>: Value] {
        entries.reduce(into: [:]) { result, entry in result[Set(entry.members)] = entry.value }
    }

    static func entries<Value>(from dictionary: [Set<String>: Value]) -> [Entry<Value>] {
        dictionary
            .map { Entry(members: $0.key.sorted(), value: $0.value) }
            // Sorted so the JSON is stable between exports.
            .sorted { $0.members.lexicographicallyPrecedes($1.members) }
    }

    static func sortedGroups(_ groups: [Set<String>]) -> [[String]] {
        groups.map { $0.sorted() }.sorted { $0.lexicographicallyPrecedes($1) }
    }
}
