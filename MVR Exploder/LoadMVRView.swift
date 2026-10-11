import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The first thing the app shows: open the MVR everything else works on.
///
/// Every tool works on the one file, so it is opened once, here, rather
/// than by each tool in turn. Once it's open the tools page takes over.
struct LoadMVRView: View {
    @ObservedObject var document: MVRDocument

    @State private var isTargeted = false
    @State private var errorMessage: String?

    // A file is only asked about when it is genuinely ambiguous about
    // which field holds the fixture ID.
    @State private var pendingFile: MVRSceneFile?
    @State private var showFieldChoice = false
    @State private var isOpening = false

    var body: some View {
        VStack(spacing: 14) {
            Text("MVR Exploder")
                .font(.largeTitle.bold())
                .padding(.bottom, 8)

            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drop a file here to edit and export")
                .font(.title2)
            if isOpening {
                ProgressView("Opening…")
                    .controlSize(.small)
            } else {
                Button("Choose MVR…") { chooseFile() }
                    .controlSize(.large)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .confirmationDialog(
            "Which field holds the fixture IDs?",
            isPresented: $showFieldChoice,
            titleVisibility: .visible
        ) {
            Button("FixtureID") { loadPending(idFieldName: "FixtureID") }
            Button("UnitNumber (Channel)") { loadPending(idFieldName: "UnitNumber") }
            Button("Cancel", role: .cancel) { pendingFile = nil }
        } message: {
            Text("This file has IDs in both. Most consoles use FixtureID; some use UnitNumber (Channel).")
        }
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
        guard !isOpening else { return }
        isOpening = true
        errorMessage = nil
        Task {
            defer { isOpening = false }
            do {
                let file = try await MVRDocument.readInBackground(from: url)
                pendingFile = file
                switch file.idField {
                case .determined(let fieldName): loadPending(idFieldName: fieldName)
                case .ambiguous: showFieldChoice = true
                }
            } catch {
                errorMessage = "Couldn't read that MVR: \(error.localizedDescription)"
            }
        }
    }

    private func loadPending(idFieldName: String) {
        guard let file = pendingFile else { return }
        pendingFile = nil
        document.load(file, idFieldName: idFieldName)
    }
}
