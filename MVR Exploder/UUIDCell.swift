import SwiftUI

/// Shows "UUID" as a greyed placeholder (blue when edited, green when
/// matched — caller decides via `color`), and reveals the real value in a
/// popover on hover. `.help()` tooltips are unreliable inside Table cells,
/// so this uses an explicit hover-driven popover instead.
struct UUIDCell: View {
    let uuid: String
    let color: Color
    @State private var isHovering = false

    var body: some View {
        Text("UUID")
            .foregroundStyle(color)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(uuid)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
    }
}
