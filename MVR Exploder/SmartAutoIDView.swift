import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Smart Auto ID as a mode of its own: open an MVR, number it, write it out.
///
/// The same engine and the same screen that used to open as a sheet over the
/// Single Edit table, with the table taken away. Numbering a rig is usually
/// the whole job rather than one edit among several, and as a sheet it was a
/// 1280-point window inside a window with a file already loaded behind it.
struct SmartAutoIDView: View {
    let onBack: () -> Void

    @StateObject private var document = MVRDocument()

    /// The run in progress. Nil before a file is open, and kept afterwards so
    /// the export screen can go back into it.
    @State private var session: AutoIDSession?
    /// Set once Apply has written the numbers into the document, which is
    /// also what puts the export screen up.
    @State private var appliedSummary: String?

    @State private var isTargeted = false
    @State private var errorMessage: String?

    // A dropped file is only asked about when the file itself is genuinely
    // ambiguous about which field holds the ID — and here the answer matters
    // more than anywhere else in the app, because the ID is what gets written.
    @State private var pendingURL: URL?
    @State private var showFieldChoice = false

    @State private var includeSceneGeometry = true
    @State private var exportMessage: String?
    @State private var exportFailed = false

    var body: some View {
        Group {
            if let session, appliedSummary == nil {
                AutoIDView(
                    session: session,
                    onCancel: { discard() },
                    onApply: { apply(session) },
                    fillsWindow: true)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    if appliedSummary == nil {
                        filePicker
                    } else {
                        exportStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
                // The whole window takes a drop, the same as the other
                // modes — including the export screen, where dropping the
                // next file is how you move on to it. The one screen that
                // doesn't is the numbering itself, where a stray drop
                // would throw a sitting's work away.
                .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
            }
        }
        .confirmationDialog(
            "Which field holds each fixture's ID in this file?",
            isPresented: $showFieldChoice,
            titleVisibility: .visible
        ) {
            Button("FixtureID") { loadPending(idFieldName: "FixtureID") }
            Button("UnitNumber (Channel)") { loadPending(idFieldName: "UnitNumber") }
            Button("Cancel", role: .cancel) { pendingURL = nil }
        } message: {
            Text("This file has real data in both fields, so it can't be inferred "
                 + "automatically — most MVR exporters use FixtureID, some use "
                 + "UnitNumber (also called Channel on some consoles).")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            // From the export screen that is the numbering it came from;
            // the mode list is only ever one step behind the drop zone.
            Button("Back") {
                if appliedSummary != nil { appliedSummary = nil } else { onBack() }
            }

            Text("Smart Auto ID")
                .font(.headline)

            if !document.fileName.isEmpty {
                Text(document.fileName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(12)
    }

    // MARK: - Opening a file

    private var filePicker: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drag an .mvr file here")
                .font(.title2)
            Text("Fixtures are grouped into trusses and numbered in order. "
                 + "Nothing is written until you apply, and nothing leaves the "
                 + "app until you export.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Choose MVR…") { chooseFile() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mvr")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        begin(with: url)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "mvr" else {
                DispatchQueue.main.async { errorMessage = "Please drop a valid .mvr file." }
                return
            }
            DispatchQueue.main.async { begin(with: url) }
        }
        return true
    }

    private func begin(with url: URL) {
        pendingURL = url
        switch MVRDocument.detectIDField(at: url) {
        case .determined(let fieldName): loadPending(idFieldName: fieldName)
        case .ambiguous: showFieldChoice = true
        }
    }

    private func loadPending(idFieldName: String) {
        guard let url = pendingURL else { return }
        pendingURL = nil

        do {
            try document.load(from: url, idFieldName: idFieldName)
            errorMessage = nil
            exportMessage = nil
            appliedSummary = nil
            // A file carrying a previous run picks it up where it was left,
            // the same as the sheet did.
            session = AutoIDSession(
                fixtures: document.fixtures,
                storedNames: document.groupNames,
                session: document.autoIDSession)
        } catch {
            errorMessage = "Couldn't read that MVR: \(error.localizedDescription)"
        }
    }

    // MARK: - The run

    private func apply(_ session: AutoIDSession) {
        let changed = session.plan.changedCount
        session.apply(to: document)
        appliedSummary = "\(changed) fixture ID\(changed == 1 ? "" : "s") changed."
    }

    /// Cancelled out of the numbering — back to the drop zone with nothing
    /// kept. The warning about losing work has already been shown by then.
    private func discard() {
        session = nil
        appliedSummary = nil
        document.clear()
    }

    // MARK: - Exporting

    private var exportStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Numbering applied")
                .font(.title3)
            Text(appliedSummary ?? "")
                .foregroundStyle(.secondary)
            Text("The numbers are in the document, not in the file. Export to "
                 + "write them out — the run itself rides along, so re-opening "
                 + "the exported file resumes it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Toggle("Include scene geometry", isOn: $includeSceneGeometry)
                .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                Button("Back to the Numbering") { appliedSummary = nil }
                Button("Open Another MVR") { discard() }
                    .help("Or drag the next .mvr file onto this window.")
                Button("Export MVR…") { exportMVR() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)

            if let exportMessage {
                Text(exportMessage)
                    .font(.callout)
                    .foregroundStyle(exportFailed ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportMVR() {
        let panel = NSSavePanel()
        let base = (document.fileName as NSString).deletingPathExtension
        panel.prepareForExport(named: "\(base)_autoID", fileExtension: "mvr")
        panel.canCreateDirectories = true
        panel.title = "Export MVR"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let options = MVRExportOptions(
            includeSceneGeometry: includeSceneGeometry,
            assignLayersByFixtureType: false,
            replaceAllWithDummyGDTFs: false,
            cleanupEmptyClassesAndLayers: false)

        do {
            try MVRExporter.export(document, to: url.ensuringPathExtension("mvr"), options: options)
            exportFailed = false
            exportMessage = "Exported \(url.lastPathComponent)."
        } catch {
            exportFailed = true
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SmartAutoIDView(onBack: {})
}
