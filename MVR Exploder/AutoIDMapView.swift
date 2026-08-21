import SwiftUI

/// The Fixture ID Map, but of the numbering that hasn't happened yet.
///
/// The 3D preview answers "which fixtures are in this group and which way
/// do the numbers run"; it can't answer "what does the patch end up looking
/// like" — where the blocks land, how much room is left in each, and
/// whether the run walks into IDs that types left out of it already hold.
/// Same grid, same collapsed gaps as the real map, so the two read alike.
///
/// Colour means *group* here rather than fixture type, matching the swatches
/// in the groups list and the boxes in 3D. One meaning for colour across the
/// whole sheet is worth more than colouring every type at once, which the
/// type list already ranges for you.
struct AutoIDMapView: View {
    @ObservedObject var session: AutoIDSession
    let selectedSpec: String?
    /// Group colours for the selected type, index-aligned with the groups
    /// list — the same array that colours the 3D overlay.
    let overlays: [AutoIDGroupOverlay]
    let onSelect: (String, Int) -> Void

    private let cellSize: CGFloat = 20
    private let cellSpacing: CGFloat = 2

    var body: some View {
        let (slots, unassigned) = IDMapLayout.occupancy(
            plan: session.plan,
            fixtures: session.previewFixtures,
            includedTypes: session.includedTypes)
        let usedIDs = slots.keys.sorted()

        VStack(spacing: 0) {
            GeometryReader { proxy in
                let columns = IDMapLayout.columns(
                    fittingWidth: proxy.size.width - 24,
                    cellSize: cellSize,
                    spacing: cellSpacing)
                let segments = IDMapLayout.segments(usedIDs: usedIDs, columns: columns)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            if index > 0 {
                                skippedRange(from: segments[index - 1].end, to: segment.start)
                            }
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: columns),
                                spacing: cellSpacing
                            ) {
                                ForEach(segment.start...segment.end, id: \.self) { id in
                                    cell(id: id, occupants: slots[id] ?? [])
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            legend(slots: slots, usedIDs: usedIDs, unassigned: unassigned)
        }
        // Opaque on purpose: this sits over the still-mounted 3D view, and
        // a ScrollView paints no background of its own.
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Cells

    private func cell(id: Int, occupants: [IDMapOccupant]) -> some View {
        let primary = occupants.first
        let isClash = occupants.count > 1

        return ZStack {
            Rectangle().fill(fill(for: primary))
            Rectangle()
                .stroke(isClash ? Color.red : Color.gray.opacity(0.3), lineWidth: isClash ? 2 : 0.5)
            Text("\(id)")
                .font(.system(size: 8))
                .minimumScaleFactor(0.35)
                .lineLimit(1)
                .foregroundStyle(primary != nil ? Color.black.opacity(0.65) : Color.gray.opacity(0.7))
                .padding(.horizontal, 1)
        }
        .frame(width: cellSize, height: cellSize)
        .contentShape(Rectangle())
        .onTapGesture {
            // Jumps the rest of the sheet to whatever was clicked, which is
            // the shortest route from "what is sitting on 1043" to seeing it
            // in 3D. Retained IDs have no group to jump to.
            guard let primary, let groupIndex = primary.groupIndex else { return }
            onSelect(primary.spec, groupIndex)
        }
        .help(tooltip(id: id, occupants: occupants))
    }

    private func fill(for occupant: IDMapOccupant?) -> Color {
        guard let occupant else { return Color.gray.opacity(0.06) }
        guard occupant.isRenumbered else { return Color.orange.opacity(0.55) }
        guard occupant.spec == selectedSpec, let index = occupant.groupIndex,
              overlays.indices.contains(index) else {
            return Color.secondary.opacity(0.3)
        }
        return Color(nsColor: overlays[index].color)
    }

    private func tooltip(id: Int, occupants: [IDMapOccupant]) -> String {
        guard let primary = occupants.first else { return "\(id): free" }
        if occupants.count > 1 {
            // Marks which side is which, so a clash the run caused reads
            // differently from one the file already had.
            let names = occupants.map { $0.isRenumbered ? $0.name : $0.name + " (kept)" }
            return "Clash on \(id): " + names.joined(separator: ", ")
        }
        let where_ = primary.groupIndex
            .map { " · " + session.name(forGroup: $0, in: primary.spec) }
            ?? " · kept, not renumbered"
        return "\(id): \(primary.name) (\(session.displayName(ofType: primary.spec)))\(where_)"
    }

    private func skippedRange(from previousEnd: Int, to nextStart: Int) -> some View {
        let skipped = nextStart - previousEnd - 1
        return HStack(spacing: 8) {
            Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 1)
            Text("\(skipped.formatted()) unused IDs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Legend

    private func legend(slots: [Int: [IDMapOccupant]], usedIDs: [Int], unassigned: Int) -> some View {
        // Free slots inside the span the run occupies — the headroom left
        // in the blocks, which is what a "can I add four more" question
        // actually comes down to.
        let free: Int
        if let first = usedIDs.first, let last = usedIDs.last {
            free = (last - first + 1) - usedIDs.count
        } else {
            free = 0
        }
        let retained = slots.values.reduce(0) { $0 + $1.filter { !$0.isRenumbered }.count }

        return ScrollView(.horizontal) {
            HStack(spacing: 14) {
                groupKey
                key(Color.secondary.opacity(0.3), "Other types in the run", filled: true)
                if retained > 0 {
                    key(Color.orange.opacity(0.55), "Kept, not renumbered", filled: true)
                }
                // Keyed off the map, not off plan.collisions: IDs the file
                // already had twice over show red here too, and they are
                // worth seeing even though the run did not cause them.
                if slots.values.contains(where: { $0.count > 1 }) {
                    key(.red, "Clash", filled: false)
                }

                Divider().frame(height: 14)

                Text(summary(assigned: session.plan.assignments.count, free: free, unassigned: unassigned))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// A few of the actual group colours rather than a stand-in swatch, so
    /// the key matches the rows in the groups list beside it.
    private var groupKey: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(Array(overlays.prefix(4).enumerated()), id: \.offset) { _, overlay in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: overlay.color))
                        .frame(width: 8, height: 12)
                }
                if overlays.isEmpty {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 12, height: 12)
                }
            }
            Text("This type's groups").font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }

    private func summary(assigned: Int, free: Int, unassigned: Int) -> String {
        var parts = ["\(assigned) assigned", "\(free.formatted()) free in range"]
        // Off the map by design, so it has to be said rather than drawn.
        if unassigned > 0 { parts.append("\(unassigned) kept with no ID") }
        return parts.joined(separator: " · ")
    }

    private func key(_ color: Color, _ label: String, filled: Bool) -> some View {
        HStack(spacing: 5) {
            Group {
                if filled {
                    RoundedRectangle(cornerRadius: 3).fill(color)
                } else {
                    RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 2)
                }
            }
            .frame(width: 12, height: 12)

            Text(label).font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }
}
