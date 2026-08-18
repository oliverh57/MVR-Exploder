import SwiftUI

/// A delete "✕" that's grey at rest and turns red on hover, so it doesn't
/// visually shout at you from every row. Shared by Single Edit and Compare.
struct DeleteRowButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? .red : .gray)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Remove this fixture")
    }
}
