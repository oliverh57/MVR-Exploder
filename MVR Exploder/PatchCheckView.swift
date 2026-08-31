import SwiftUI

/// What's wrong with the patch: fixtures sharing channels, and fixtures
/// running off the end of their universe.
///
/// The check needs a channel count per fixture, which means opening every
/// GDTF in the file — a zip full of meshes each — so it runs on a
/// background task and the sheet says so while it works.
struct PatchCheckView: View {
    @ObservedObject var document: MVRDocument
    let onClose: () -> Void
    /// Reveals a fixture in the table behind the sheet.
    let onSelectFixtures: (Set<String>) -> Void

    @State private var patches: [MVRPatchCheck.Patch] = []
    @State private var findings: [MVRPatchCheck.Finding] = []
    @State private var unknownTypes: Set<String> = []
    @State private var suspectTypes: [MVRPatchCheck.SuspectFootprint] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if isLoading {
                loading
            } else if findings.isEmpty && suspectTypes.isEmpty {
                clean
            } else {
                findingsList
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        .task { await check() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Patch Check")
                .font(.headline)
            Text("Every fixture's channel range, from its GDTF mode, checked against every other.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading channel counts from the fixture types…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clean: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(patches.isEmpty
                 ? "Nothing to check — no fixture in this file has both an address and a known channel count."
                 : "No overlaps. \(patches.count.formatted()) fixtures checked.")
                .font(.callout)
                .multilineTextAlignment(.center)
            usageSummary
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var findingsList: some View {
        List {
            // Above the findings, because it explains why some of the rig
            // isn't in them.
            ForEach(suspectTypes, id: \.spec) { suspect in
                label(
                    icon: "questionmark.circle",
                    tint: .yellow,
                    title: "\(GDTFSpecName.readable(suspect.spec)) — not checked",
                    detail: "Its GDTF says \(suspect.declared) channels, but the "
                        + "\(suspect.fixtureCount) in this file are patched \(suspect.spacing) apart. "
                        + "The file is the better witness, so this type is left out.")
            }

            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                Button {
                    onSelectFixtures(Set(finding.fixtureIDs))
                    onClose()
                } label: {
                    row(for: finding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func row(for finding: MVRPatchCheck.Finding) -> some View {
        switch finding {
        case let .overlap(universe, channels, ids):
            label(
                icon: "exclamationmark.2",
                tint: .orange,
                title: "Universe \(universe), channels \(channels.lowerBound)–\(channels.upperBound)",
                detail: names(ids).joined(separator: "  ·  "))
        case let .overrun(id, universe, last):
            label(
                icon: "arrow.right.to.line",
                tint: .red,
                title: "Universe \(universe) ends at 512, this reaches \(last)",
                detail: names([id]).joined())
        }
    }

    private func label(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var usageSummary: some View {
        let usage = MVRPatchCheck.usage(in: patches)
        if !usage.isEmpty {
            Text(usage
                .map { "U\($0.universe) \($0.used * 100 / MVRPatchCheck.universeSize)%" }
                .joined(separator: "   "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !isLoading, !unknownTypes.isEmpty {
                // Said plainly rather than hidden: a check that quietly
                // skipped a third of the rig would read as a clean bill of
                // health for fixtures nobody looked at.
                Image(systemName: "questionmark.circle")
                Text("\(unknownTypes.count) fixture type\(unknownTypes.count == 1 ? "" : "s") "
                     + "left out — their GDTF doesn't give a channel count.")
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isLoading, !findings.isEmpty {
                Text("Click a row to find those fixtures in the table.")
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
    }

    // MARK: - Work

    private func check() async {
        guard let url = document.originalFileURL else { isLoading = false; return }
        let specs = document.fixtures.map(\.gdtfSpec)
        let fixtures = document.fixtures

        let footprints = await Task.detached(priority: .userInitiated) {
            GDTFFootprintLoader.load(mvrURL: url, specs: specs)
        }.value

        let placed = MVRPatchCheck.placements(fixtures: fixtures, footprints: footprints)
        patches = placed.patches
        unknownTypes = placed.unknownTypes
        suspectTypes = placed.suspectTypes
        findings = MVRPatchCheck.findings(in: placed.patches)
        isLoading = false
    }

    private func names(_ ids: [String]) -> [String] {
        ids.compactMap { id in
            guard let fixture = document.fixtures.first(where: { $0.id == id }) else { return nil }
            let channels = patches.first { $0.fixtureID == id }.map { " (\($0.footprint) ch)" } ?? ""
            return "\(fixture.name)\(channels)"
        }
    }
}
