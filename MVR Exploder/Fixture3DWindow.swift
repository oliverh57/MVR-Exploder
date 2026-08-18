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

    func present(fixtures: [MVRFixture], document: MVRDocument, fileName: String) {
        // Rebuilt each time so the view always reflects the current
        // fixtures, matching how the sheet used to behave.
        close()

        let controller = NSHostingController(
            rootView: Fixture3DView(fixtures: fixtures, document: document) { [weak self] in
                self?.close()
            }
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
