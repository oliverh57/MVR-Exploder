import SwiftUI

/// A table cell whose value can be edited in place.
///
/// Hovering reveals a pencil; clicking it opens a small popover with a text
/// field, rather than swapping the cell itself for one. A `Table` cell is
/// only a few points tall and gets rebuilt as rows are sorted and filtered,
/// which makes an inline field awkward to focus and easy to lose mid-edit —
/// the popover is stable, has room for a validation message, and makes
/// "commit" versus "cancel" explicit.
///
/// An edited value shows in blue, with a revert button beside it that undoes
/// just this field.
struct EditableCell<Content: View>: View {
    let isEdited: Bool
    /// Seed value for the editor, i.e. the current value as plain text.
    let editText: String
    /// Rejects a proposed value, returning why. Nil means accept.
    var validate: (String) -> String? = { _ in nil }
    let onCommit: (String) -> Void
    let onReset: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft = ""

    private var validationError: String? {
        validate(draft.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        HStack(spacing: 4) {
            content()

            Spacer(minLength: 0)

            // Reserved whether or not it's showing, so revealing the pencil
            // on hover doesn't shove the value sideways.
            Button {
                draft = editText
                isEditing = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .help("Edit this value")
            .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                editor
            }

            if isEdited {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Revert this value to the one in the original file")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Value", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(commit)

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { isEditing = false }
                Button("Apply", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil)
            }
        }
        .padding(14)
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard validate(value) == nil else { return }
        onCommit(value)
        isEditing = false
    }
}

/// The layer variant: a menu of the layers already in the file rather than a
/// free-text field, since a layer is identified by uuid — typing a name that
/// merely matches an existing layer would point the fixture at a different
/// layer that happens to look right.
struct EditableLayerCell: View {
    let layerName: String
    let isEdited: Bool
    let layers: [MVRLayerRef]
    let onSelect: (MVRLayerRef) -> Void
    let onReset: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(layerName.isEmpty ? "-" : layerName)
                .foregroundStyle(isEdited ? .blue : .primary)

            Spacer(minLength: 0)

            Menu {
                ForEach(layers) { layer in
                    Button(layer.name) { onSelect(layer) }
                }
            } label: {
                Image(systemName: "pencil")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .disabled(layers.isEmpty)
            .help("Move this fixture to another layer")

            if isEdited {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Revert this value to the one in the original file")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
