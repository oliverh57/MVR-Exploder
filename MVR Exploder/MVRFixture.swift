import Foundation

struct MVRFixture: Identifiable {
    /// Stable internal identity for SwiftUI — intentionally separate from
    /// the MVR uuid below, since that value can now be edited/regenerated.
    let id: String

    var name: String

    let originalFixtureID: Int?
    var currentFixtureID: Int?

    /// Absolute DMX address (1-based, spans universes in blocks of 512).
    let originalAddress: Int?
    var currentAddress: Int?

    let originalUUID: String
    var currentUUID: String

    var gdtfSpec: String
    var mode: String

    /// Which <Layer> this fixture currently lives under, by name and uuid —
    /// both matter: MA (and likely other consumers) identify a layer by its
    /// uuid, not its name, so copying only the name creates a "duplicate"
    /// layer with a different identity.
    var layerName: String
    var layerUUID: String
    /// The MVR "classing" attribute — a grouping/filtering concept some
    /// consoles use, unrelated to programming classes.
    var classing: String
    /// Raw <Matrix> transform text (position/rotation in 3D space).
    var matrixText: String

    /// Live DOM nodes backing this fixture, so edits can be written back
    /// into the document before export.
    let xmlElement: XMLElement          // the <Fixture> element (uuid attribute, FixtureID)
    let addressElement: XMLElement?     // the first <Address> element, if any

    var isFixtureIDEdited: Bool {
        currentFixtureID != originalFixtureID
    }

    var isAddressEdited: Bool {
        currentAddress != originalAddress
    }

    var isUUIDEdited: Bool {
        currentUUID != originalUUID
    }

    var universe: String {
        guard let address = currentAddress else { return "-" }
        return String(Self.universeAndChannel(fromAbsoluteAddress: address).universe)
    }

    var channel: String {
        guard let address = currentAddress else { return "-" }
        return String(Self.universeAndChannel(fromAbsoluteAddress: address).channel)
    }

    static func universeAndChannel(fromAbsoluteAddress address: Int) -> (universe: Int, channel: Int) {
        let zeroBased = address - 1
        return ((zeroBased / 512) + 1, (zeroBased % 512) + 1)
    }

    // MARK: - Sorting

    /// KeyPathComparator needs non-optional Comparable values, so these
    /// give sortable table columns something to key off — missing values
    /// sort to the bottom via Int.min.
    var sortableFixtureID: Int { currentFixtureID ?? Int.min }
    var sortableAddress: Int { currentAddress ?? Int.min }
    var sortableUniverse: Int {
        currentAddress.map { Self.universeAndChannel(fromAbsoluteAddress: $0).universe } ?? Int.min
    }
    var sortableChannel: Int {
        currentAddress.map { Self.universeAndChannel(fromAbsoluteAddress: $0).channel } ?? Int.min
    }

    /// Absent or explicitly zero both mean "no real patch" in practice —
    /// some exporters omit the element, others write a literal 0.
    var hasNoDMXPatch: Bool {
        (currentAddress ?? 0) == 0
    }

    var hasNoFixtureID: Bool {
        (currentFixtureID ?? 0) == 0
    }

    enum UnpatchedCriteria {
        case noDMXPatch
        case noFixtureID
        case both
    }

    func isUnpatched(by criteria: UnpatchedCriteria) -> Bool {
        switch criteria {
        case .noDMXPatch: return hasNoDMXPatch
        case .noFixtureID: return hasNoFixtureID
        case .both: return hasNoDMXPatch && hasNoFixtureID
        }
    }
}
