import SwiftUI

struct ModeSelectionView: View {
    let onSelect: (AppMode) -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("MVR Exploder")
                    .font(.largeTitle.bold())
                Text("Choose a mode to get started")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                modeCard(
                    title: "Single Edit",
                    subtitle: "Import one MVR file, offset fixture IDs or universes, regenerate UUIDs, and export.",
                    systemImage: "square.and.pencil"
                ) {
                    onSelect(.singleEdit)
                }

                modeCard(
                    title: "Compare",
                    subtitle: "Import two MVR files, match their fixtures by UUID or Fixture ID, and see them side by side.",
                    systemImage: "rectangle.split.2x1"
                ) {
                    onSelect(.compare)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func modeCard(title: String, subtitle: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 34))
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(width: 250, height: 210)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
