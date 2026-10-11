//
//  MVR_ExploderApp.swift
//  MVR Exploder
//
//  Created by Oliver Hynds on 23/07/2026.
//

import SwiftUI
import AppKit

@main
struct MVR_ExploderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    /// The one file the app works on. Held here rather than by the window,
    /// so closing the window doesn't take an edited file with it.
    @StateObject private var document = MVRDocument()

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView(document: document)
                .onAppear {
                    applyAppearance()
                    appDelegate.document = document
                }
                .onChange(of: appearanceModeRaw) { _, _ in applyAppearance() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await Updater.shared.check(userInitiated: true) }
                }
            }
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: $appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            }
        }
    }

    // NSApp.appearance cascades to every window the app owns, including ones
    // built outside the WindowGroup scene (like the 3D viewer's own
    // NSWindow). SwiftUI's `.preferredColorScheme` only affects the view
    // hierarchy it's attached to — window chrome and any other window kept
    // following the system setting regardless, which is what caused some UI
    // to stay dark while the rest followed System.
    private func applyAppearance() {
        switch appearanceMode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Asks before quitting throws away edits that were never exported.
///
/// Edits reach the document when a tool's Apply is pressed; leaving a tool
/// any other way asks there. Quitting is one of the two ways applied edits
/// can still be lost; closing the file from the tools page is the other.
/// A tool's unapplied work isn't covered here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var document: MVRDocument?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Not when hosting unit tests: an update alert would stall the run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { await Updater.shared.check(userInitiated: false) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let document, document.isLoaded, document.hasUnexportedChanges else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit without exporting \(document.fileName)?"
        alert.informativeText = "Your changes haven't been exported."
        alert.addButton(withTitle: "Cancel")
        let quit = alert.addButton(withTitle: "Quit Without Exporting")
        quit.hasDestructiveAction = true

        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
