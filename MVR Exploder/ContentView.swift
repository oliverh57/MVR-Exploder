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
            case .compare:
                CompareView(onBack: { mode = nil })
            }
        }
        .frame(minWidth: 780, minHeight: 480)
    }
}

#Preview {
    ContentView()
}
