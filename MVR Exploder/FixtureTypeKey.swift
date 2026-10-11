import SwiftUI

/// The fixture types in a file, as the Fixture ID map and the DMX universe
/// map colour and name them — shared so the same type is the same colour
/// in both.
///
/// Built once per map rather than looked up per cell: with thousands of
/// cells, regrouping every fixture on every cell's render made the ID map
/// effectively unusable above a few hundred fixtures.
struct FixtureTypeKey {
    let specs: [String]
    /// How many fixtures of each type are in the file.
    let counts: [String: Int]
    /// What each type is called on screen: the readable name and its
    /// modes, rather than the raw spec — "BEAM 1 — Standard", not
    /// "Dummy_BEAM 1.gdtf".
    private let labels: [String: String]
    private let colorIndex: [String: Int]

    init(fixtures: [MVRFixture]) {
        let specs = Set(fixtures.map(\.gdtfSpec)).sorted()
        self.specs = specs
        var indexMap: [String: Int] = [:]
        for (index, spec) in specs.enumerated() {
            indexMap[spec] = index
        }
        self.colorIndex = indexMap

        let names = GDTFSpecName.readableNames(for: specs)
        var modes: [String: Set<String>] = [:]
        for fixture in fixtures where fixture.mode != "-" && !fixture.mode.isEmpty {
            modes[fixture.gdtfSpec, default: []].insert(fixture.mode)
        }
        var labels: [String: String] = [:]
        for spec in specs {
            let name = names[spec] ?? spec
            let specModes = (modes[spec] ?? []).sorted()
            labels[spec] = specModes.isEmpty ? name : "\(name) — \(specModes.joined(separator: ", "))"
        }
        self.labels = labels
        self.counts = Dictionary(grouping: fixtures, by: \.gdtfSpec).mapValues(\.count)
    }

    func label(for spec: String) -> String { labels[spec] ?? spec }

    /// Evenly-spaced hues around the color wheel, so any number of GDTF
    /// types get visually distinct colors rather than reusing a small
    /// fixed palette. O(1) lookup via the precomputed index map.
    ///
    /// `brightness` is for a darker shade of the same colour, which the
    /// DMX map uses for a fixture's later channels.
    func color(for spec: String, brightness: Double = 0.62) -> Color {
        guard let index = colorIndex[spec], !specs.isEmpty else { return .gray }
        let hue = Double(index) / Double(specs.count)
        // Muted, so light text sits on every one of them and a screen full
        // of colour stays easy to look at.
        return Color(hue: hue, saturation: 0.55, brightness: brightness)
    }
}

/// The key, down the right of a map: one line per type, wrapping rather
/// than cutting a long name short, then whatever else the map's cells can
/// show.
struct FixtureTypeLegend<Footer: View>: View {
    let types: FixtureTypeKey
    @ViewBuilder let footer: Footer

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Fixture types")
                    Spacer()
                    Text("Qty")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(types.specs, id: \.self) { spec in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(types.color(for: spec))
                            .frame(width: 14, height: 14)
                        Text(types.label(for: spec))
                            .font(.caption)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Text(verbatim: String(types.counts[spec] ?? 0))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                footer
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
