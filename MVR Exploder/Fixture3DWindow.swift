import SwiftUI
import AppKit
import Combine

/// Presents the 3D view in its own window rather than as a sheet.
///
/// macOS sheets have no resize control — they size to their content and
/// stay there — which is limiting for a spatial view of a large plot. A
/// real window gives resizing, zoom and full screen, and lets the fixture
/// table stay usable alongside it.
@MainActor
final class Fixture3DWindowPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?
    /// The editor window this was opened from, so revealing a clicked
    /// fixture can bring the table back into view.
    private weak var editorWindow: NSWindow?

    func present(
        fixtures: [MVRFixture],
        document: MVRDocument,
        fileName: String,
        autoIDGroups: [AutoIDGroupOverlay]? = nil,
        onSelectFixture: @escaping (String) -> Void
    ) {
        // Rebuilt each time so the view always reflects the current
        // fixtures, matching how the sheet used to behave.
        close()

        // Captured before the 3D window exists, while the editor is still
        // the key window.
        editorWindow = NSApp.keyWindow

        let controller = NSHostingController(
            rootView: Fixture3DView(
                fixtures: fixtures,
                document: document,
                autoIDGroups: autoIDGroups,
                onClose: { [weak self] in self?.close() },
                onSelectFixture: { [weak self] fixtureID in
                    // The 3D view opens in front of the editor, so scrolling
                    // the table without surfacing it looks like the click did
                    // nothing at all. Ordered front rather than made key, so
                    // the 3D view keeps focus and stays ready for the next
                    // click.
                    self?.editorWindow?.orderFront(nil)
                    onSelectFixture(fixtureID)
                }
            )
        )

        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = fileName.isEmpty ? "3D View" : "3D View — \(fileName)"
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.contentMinSize = NSSize(width: 820, height: 520)
        window.center()
        // Without this the window is deallocated on close while AppKit is
        // still using it.
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let window else { return }
        window.delegate = nil
        self.window = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
