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
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { applyAppearance() }
                .onChange(of: appearanceModeRaw) { _, _ in applyAppearance() }
        }
        .commands {
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
