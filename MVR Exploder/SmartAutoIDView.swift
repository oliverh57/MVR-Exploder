import SwiftUI

/// Smart Auto ID on the open file: number it, and go back to the tools.
///
/// The file is already open and exporting is on the tools page, so this is
/// the numbering screen and nothing else. Applying writes the numbers into
/// the document, where every other tool sees them; cancelling leaves the
/// document as it was.
struct SmartAutoIDView: View {
    @ObservedObject var document: MVRDocument
    let onBack: () -> Void

    /// Built once on arrival, from the document as it stands — a file
    /// carrying an earlier run picks it up where it was left.
    @State private var session: AutoIDSession?

    var body: some View {
        Group {
            if let session {
                AutoIDView(
                    session: session,
                    onCancel: onBack,
                    onApply: {
                        session.apply(to: document)
                        onBack()
                    },
                    fillsWindow: true)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            guard session == nil else { return }
            session = AutoIDSession(
                fixtures: document.fixtures,
                storedNames: document.groupNames,
                session: document.autoIDSession)
        }
    }
}
