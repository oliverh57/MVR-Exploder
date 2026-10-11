import SwiftUI

/// The window: the file first, then the tools for it.
///
/// One document for the whole app, owned above this view so it outlives
/// the window — closing the window doesn't throw an open file away, and
/// the quit check can see it.
struct ContentView: View {
    @ObservedObject var document: MVRDocument
    @Environment(\.undoManager) private var undoManager

    @State private var mode: AppMode?
    /// Fixtures to pick out when the editor opens.
    @State private var reveal: Set<String> = []

    var body: some View {
        Group {
            if !document.isLoaded {
                LoadMVRView(document: document)
            } else {
                switch mode {
                case .none:
                    ToolsView(document: document, onOpen: { open($0) })
                case .singleEdit:
                    editing("Single Edit", tag: "Edit") { draft, close in
                        SingleEditView(document: draft, reveal: reveal, onBack: close)
                    }
                case .smartAutoID:
                    SmartAutoIDView(document: document, onBack: backToTools)
                case .modeSwap:
                    editing("Mode Swap", tag: "ModeSwap") { draft, close in
                        ModeSwapView(document: draft, onBack: close)
                    }
                case .compare:
                    editing("Compare & Merge", tag: "Merge") { draft, close in
                        CompareView(leftDocument: draft, onBack: close)
                    }
                case .disguiseCSV:
                    // Makes a CSV and never edits the file, so there's
                    // nothing to apply; it asks before dropping its layout.
                    DisguiseCSVView(document: document, onBack: backToTools)
                case .viewer3D:
                    editing("3D Viewer", tag: "Edit") { draft, close in
                        Viewer3DScreen(document: draft, onClose: close)
                            .equatable()
                    }
                case .fixtureIDMap:
                    editing("Fixture ID Map", tag: "IDMap") { draft, close in
                        FixtureIDMapView(document: draft, onClose: close)
                    }
                case .dmxUniverseMap:
                    editing("DMX Universe Map", tag: "Repatch") { draft, close in
                        DMXUniverseMapView(document: draft, onClose: close)
                    }
                }
            }
        }
        .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        .navigationTitle(document.isLoaded ? document.fileName : "MVR Exploder")
        // For the file summary in every tool's header.
        .environmentObject(document)
        // A closed file sends the window back to the start, whichever
        // tool it was closed from.
        .onChange(of: document.fileName) { _, name in
            if name.isEmpty { mode = nil }
        }
        // A reload — Clear Changes — gives every fixture a new id, which
        // an open tool would still be holding the old ones of.
        .onChange(of: document.loadGeneration) { _, _ in backToTools() }
        // Undo is per visit to a tool: what's on the stack belongs to the
        // copy that tool was editing, which is gone once it closes.
        .onChange(of: mode) { _, _ in undoManager?.removeAllActions() }
    }

    /// A tool that edits, on its own copy of the file — a new one each
    /// visit, since going back to the tools takes the tool off screen.
    /// `tag` is what the tool's work adds to the exported file's name.
    private func editing<Tool: View>(
        _ name: String,
        tag: String,
        @ViewBuilder tool: @escaping (MVRDocument, @escaping () -> Void) -> Tool
    ) -> some View {
        EditingTool(document: document, name: name, tag: tag, onClose: backToTools, tool: tool)
    }

    private func open(_ tool: AppMode) {
        reveal = []
        mode = tool
    }

    /// Back to the tools. Never asks itself: a tool asks before it calls
    /// this, if it has work to lose.
    private func backToTools() {
        reveal = []
        mode = nil
    }

    /// Each screen's own minimum, raised to the window.
    ///
    /// A screen that asks for more room than the window allows doesn't
    /// shrink — it overflows and gets clipped, which is how the Smart Auto
    /// ID header ended up off the left edge. The window has to be the one
    /// holding the floor.
    private var minimumSize: CGSize {
        guard document.isLoaded else { return CGSize(width: 780, height: 480) }
        switch mode {
        case .none:
            // Three columns across and their padding.
            return CGSize(width: 900, height: 600)
        case .singleEdit, .compare, .modeSwap:
            return CGSize(width: 780, height: 480)
        case .viewer3D:
            return CGSize(width: 820, height: 520)
        case .fixtureIDMap, .dmxUniverseMap:
            return CGSize(width: FixtureIDMapView.minimumWidth, height: 520)
        case .smartAutoID:
            // Three panes side by side, so this one needs real width.
            return CGSize(width: 1120, height: 700)
        case .disguiseCSV:
            return CGSize(width: 900, height: 620)
        }
    }
}

/// The 3D viewer, built once per visit.
///
/// The viewer builds its whole scene when it's created. This window
/// re-renders every time the document changes — which, with the fixture
/// editor open in the viewer, is every edit — and without this the scene
/// was rebuilt each time, taking the camera and the loaded geometry with
/// it. Compared on the document alone, so the viewer is made once and then
/// left to keep its own state.
private struct Viewer3DScreen: View, Equatable {
    let document: MVRDocument
    let onClose: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.document === rhs.document }

    var body: some View {
        Fixture3DView(
            fixtures: document.fixtures,
            document: document,
            onClose: onClose,
            onSelectFixture: { _ in })
    }
}

/// Any tool that edits, under the Smart Auto ID rule: it works on its own
/// copy of the file, nothing reaches the file until Apply, and Cancel or
/// "← Tools" leaves the file as it was — asking first if there's work in
/// the copy to lose.
private struct EditingTool<Tool: View>: View {
    @ObservedObject var document: MVRDocument
    let name: String
    let tag: String
    let onClose: () -> Void
    @ViewBuilder let tool: (MVRDocument, @escaping () -> Void) -> Tool

    @Environment(\.undoManager) private var undoManager
    @State private var draft: MVRDocument?
    @State private var failed = false

    var body: some View {
        Group {
            if let draft {
                DraftScreen(
                    draft: draft, name: name,
                    onApply: {
                        document.adopt(draft, as: tag)
                        onClose()
                    },
                    onCancel: onClose,
                    tool: tool)
            } else if failed {
                VStack(spacing: 12) {
                    Text("Couldn't open \(name).")
                    Button("← Tools", action: onClose)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard draft == nil, !failed else { return }
            let made = await document.makeDraft()
            made?.undoManager = undoManager
            draft = made
            failed = made == nil
        }
    }
}

/// The tool itself, watching its copy so Apply knows when there's
/// something to apply.
private struct DraftScreen<Tool: View>: View {
    @ObservedObject var draft: MVRDocument
    let name: String
    let onApply: () -> Void
    let onCancel: () -> Void
    let tool: (MVRDocument, @escaping () -> Void) -> Tool

    @State private var isConfirmingDiscard = false

    var body: some View {
        tool(draft, requestCancel)
            // The header's file summary follows the copy, so it shows the
            // edits being made here.
            .environmentObject(draft)
            .environment(\.toolEditActions, ToolEditActions(
                canApply: draft.editCount > 0,
                cancel: requestCancel,
                apply: onApply))
            .alert("Discard your changes in \(name)?", isPresented: $isConfirmingDiscard) {
                Button("Discard", role: .destructive) { onCancel() }
                Button("Keep Working", role: .cancel) {}
            } message: {
                Text("Your changes in this tool will be lost.")
            }
    }

    /// Nothing done, nothing to lose — asking would just be a click in
    /// the way.
    private func requestCancel() {
        if draft.editCount > 0 {
            isConfirmingDiscard = true
        } else {
            onCancel()
        }
    }
}
