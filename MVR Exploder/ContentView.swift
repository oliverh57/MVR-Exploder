import SwiftUI

struct ContentView: View {
    @State private var mode: AppMode?

    var body: some View {
        Group {
            switch mode {
            case .none:
                ModeSelectionView { selected in
                    mode = selected
                }
            case .singleEdit:
                SingleEditView(onBack: { mode = nil })
            case .smartAutoID:
                SmartAutoIDView(onBack: { mode = nil })
            case .compare:
                CompareView(onBack: { mode = nil })
            case .disguiseCSV:
                DisguiseCSVView(onBack: { mode = nil })
            }
        }
        .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
    }

    /// Each mode's own minimum, raised to the window.
    ///
    /// A mode that asks for more room than the window allows doesn't
    /// shrink — it overflows and gets clipped, which is how the Smart Auto
    /// ID header ended up off the left edge. The window has to be the one
    /// holding the floor.
    private var minimumSize: CGSize {
        switch mode {
        case .none, .singleEdit, .compare:
            return CGSize(width: 780, height: 480)
        case .smartAutoID:
            // Three panes side by side, so this one needs real width.
            return CGSize(width: 1120, height: 700)
        case .disguiseCSV:
            return CGSize(width: 900, height: 620)
        }
    }
}

#Preview {
    ContentView()
}
