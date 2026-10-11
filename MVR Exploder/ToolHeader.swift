import SwiftUI

/// The bar across the top of every tool, in two rows.
///
/// The first is the same everywhere: the way back to the tools, the tool's
/// name — the one its card on the tools page uses — and the open file. The
/// second is the tool's own controls, with the whole width to themselves.
/// One row for both crushed everything: the 3D viewer's controls squeezed
/// the file name to nothing and stood its fixture count on end.
struct ToolHeader<Content: View>: View {
    let title: String
    let onBack: () -> Void
    private let hasControls: Bool
    @ViewBuilder var content: Content

    @EnvironmentObject private var document: MVRDocument
    @Environment(\.toolEditActions) private var editActions

    init(_ title: String, onBack: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onBack = onBack
        self.hasControls = true
        self.content = content()
    }

    fileprivate init(title: String, onBack: @escaping () -> Void, content: Content) {
        self.title = title
        self.onBack = onBack
        self.hasControls = false
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button("← Tools", action: onBack)
                    .fixedSize()
                    .help("Back to the tools.")
                Text(title)
                    .font(.headline)
                    .fixedSize()
                Spacer(minLength: 24)
                FileSummary(document: document, compact: true)
                if let editActions {
                    Divider().frame(height: 20)
                    Button("Cancel", action: editActions.cancel)
                        .keyboardShortcut(editActions.usesKeys ? .cancelAction : nil)
                        .fixedSize()
                    Button("Apply", action: editActions.apply)
                        .keyboardShortcut(editActions.usesKeys ? .defaultAction : nil)
                        .buttonStyle(.borderedProminent)
                        .disabled(!editActions.canApply)
                        .fixedSize()
                        .help("Keep this tool's changes and go back to the tools.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if hasControls {
                Divider()
                HStack(spacing: 12) {
                    content
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

/// A tool's Cancel and Apply, for the header to show. Set by a tool that
/// edits, which every one but Disguise CSV does.
struct ToolEditActions {
    /// False until there's something to apply.
    var canApply: Bool
    /// Asks first when there's work to lose, the same as "← Tools".
    var cancel: () -> Void
    var apply: () -> Void
    /// Escape and Return. Only where no text field is ever in reach of
    /// them — in a tool with a search field, Escape would leave the tool.
    var usesKeys = false
}

extension EnvironmentValues {
    @Entry var toolEditActions: ToolEditActions?
}

extension ToolHeader where Content == EmptyView {
    /// A tool with nothing of its own to put up top.
    init(_ title: String, onBack: @escaping () -> Void) {
        self.init(title: title, onBack: onBack, content: EmptyView())
    }
}

/// The open file at a glance: its name, whether it has edits nobody has
/// exported, and what's in it. Kept live, so it follows the edits made in
/// the tools.
struct FileSummary: View {
    @ObservedObject var document: MVRDocument
    /// A line under the summary, like the result of the last export.
    var note: Text?
    /// One line, for a tool's header, rather than the tools page's block.
    var compact = false

    @State private var isConfirmingClear = false
    @State private var isClearing = false
    @State private var clearError: String?

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.secondary)
                    nameLine
                    if let clearError {
                        Text(clearError).font(.caption).foregroundStyle(.red).lineLimit(1)
                    } else {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        nameLine
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let clearError {
                            Text(clearError).font(.caption).foregroundStyle(.red)
                        } else if let note {
                            note.font(.caption)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear every change to \(document.fileName)?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Changes", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file goes back to how it was when it was opened: edits, deletes and merges are all thrown away. This can't be undone.")
        }
    }

    /// The name, and when there are edits, the badge and the way to drop
    /// them.
    private var nameLine: some View {
        HStack(spacing: 8) {
            Text(document.fileName)
                .font(compact ? .headline : .title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if document.hasUnexportedChanges {
                // Said where the export button is, because that is what
                // it's asking for.
                Label("Unsaved changes", systemImage: "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
                    .fixedSize()
                // On the tools page only. In a tool, Cancel is how its
                // changes are dropped; everything else is out here.
                if compact {
                    EmptyView()
                } else if isClearing {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Clear Changes…") { isConfirmingClear = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Throw away every change and go back to the file as it was opened.")
                }
            }
        }
    }

    private func clear() {
        isClearing = true
        clearError = nil
        Task {
            defer { isClearing = false }
            do {
                try await document.revertToOpenedFile()
            } catch {
                clearError = "Couldn't reopen the file: \(error.localizedDescription)"
            }
        }
    }

    private var summary: String {
        let fixtures = document.fixtures
        let types = Set(fixtures.map(\.gdtfSpec)).count
        let universes = Set(fixtures.compactMap { fixture in
            fixture.currentAddress.map {
                MVRFixture.universeAndChannel(fromAbsoluteAddress: $0).universe
            }
        }).count
        let noPatch = fixtures.filter(\.hasNoDMXPatch).count
        let noID = fixtures.filter(\.hasNoFixtureID).count

        var parts = [
            "\(fixtures.count) fixture\(fixtures.count == 1 ? "" : "s")",
            "\(types) type\(types == 1 ? "" : "s")",
        ]
        if universes > 0 { parts.append("\(universes) universe\(universes == 1 ? "" : "s")") }
        if noPatch > 0 { parts.append("\(noPatch) with no DMX patch") }
        if noID > 0 { parts.append("\(noID) with no fixture ID") }
        return parts.joined(separator: "  ·  ")
    }
}
