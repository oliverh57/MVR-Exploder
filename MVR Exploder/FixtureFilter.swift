import Foundation

/// Which field a table's filter bar matches against. Shared by Single Edit
/// and Compare so both filter the same way.
enum FixtureFilterField: String, CaseIterable, Identifiable {
    case name = "Name"
    case fixtureID = "Fixture ID"
    case layer = "Layer"
    case gdtfSpec = "GDTF Spec"
    case mode = "Mode"

    var id: String { rawValue }
}

extension MVRFixture {
    /// Case-insensitive substring match against the chosen field. An empty
    /// filter text always matches.
    func matchesFilter(_ text: String, field: FixtureFilterField) -> Bool {
        guard !text.isEmpty else { return true }
        let needle = text.lowercased()
        let haystack: String
        switch field {
        case .name: haystack = name
        case .fixtureID: haystack = currentFixtureID.map(String.init) ?? ""
        case .layer: haystack = layerName
        case .gdtfSpec: haystack = gdtfSpec
        case .mode: haystack = mode
        }
        return haystack.lowercased().contains(needle)
    }
}
