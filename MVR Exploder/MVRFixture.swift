import Foundation

struct MVRFixture: Identifiable {
    /// Stable internal identity for SwiftUI — intentionally separate from
    /// the MVR uuid below, since that value can now be edited/regenerated.
    let id: String

    let originalName: String
    var name: String

    let originalFixtureID: Int?
    var currentFixtureID: Int?

    /// Absolute DMX address (1-based, spans universes in blocks of 512).
    let originalAddress: Int?
    var currentAddress: Int?

    let originalUUID: String
    var currentUUID: String

    var gdtfSpec: String

    let originalMode: String
    var mode: String

    /// Which <Layer> this fixture currently lives under, by name and uuid —
    /// both matter: MA (and likely other consumers) identify a layer by its
    /// uuid, not its name, so copying only the name creates a "duplicate"
    /// layer with a different identity.
    let originalLayerName: String
    var layerName: String
    let originalLayerUUID: String
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

    var isNameEdited: Bool {
        name != originalName
    }

    var isModeEdited: Bool {
        mode != originalMode
    }

    /// A layer is identified by uuid, not name (see `layerUUID`), so a move
    /// counts as an edit even if two layers happen to share a name.
    var isLayerEdited: Bool {
        layerUUID != originalLayerUUID || layerName != originalLayerName
    }

    /// Which of this fixture's fields differ from the loaded file.
    func isEdited(_ field: MVRFixtureField) -> Bool {
        switch field {
        case .name: return isNameEdited
        case .fixtureID: return isFixtureIDEdited
        case .uuid: return isUUIDEdited
        case .layer: return isLayerEdited
        case .universe, .channel: return isAddressEdited
        case .mode: return isModeEdited
        }
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
    /// Stage position in millimetres, for sorting a table by where things
    /// physically are. Unpositioned fixtures sort to the bottom.
    var sortableX: Int { position3D.map { Int($0.x) } ?? Int.max }
    var sortableY: Int { position3D.map { Int($0.y) } ?? Int.max }
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

/// The fixture fields the table can edit in place and revert individually.
///
/// GDTF Spec is deliberately absent: changing it isn't editing a value so
/// much as substituting the fixture type, which only holds up if a matching
/// `.gdtf` is present in the file. Export would quietly generate a dummy
/// instead, which is not what someone retyping a spec would expect.
enum MVRFixtureField: String, CaseIterable, Identifiable {
    case name
    case fixtureID
    case uuid
    case layer
    case universe
    case channel
    case mode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .fixtureID: return "Fixture ID"
        case .uuid: return "UUID"
        case .layer: return "Layer"
        case .universe: return "Universe"
        case .channel: return "Channel"
        case .mode: return "Mode"
        }
    }
}

extension MVRFixture {
    /// Best-effort extraction of (x, y, z) from the raw <Matrix> text, in
    /// the MVR's own frame: millimetres, X across the stage, Y depth, Z up.
    ///
    /// Pulls every number out of the string (regardless of how MVR groups
    /// them in braces) and takes the last three as the translation —
    /// translation conventionally comes last in any 4x4 or 3x4 matrix
    /// layout, row-major or column-major.
    var position3D: (x: Double, y: Double, z: Double)? {
        guard !matrixText.isEmpty else { return nil }

        let cleaned = matrixText.replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: ",", with: " ")

        let numbers = cleaned.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }

        let last3 = Array(numbers.suffix(3))
        return (last3[0], last3[1], last3[2])
    }
}
