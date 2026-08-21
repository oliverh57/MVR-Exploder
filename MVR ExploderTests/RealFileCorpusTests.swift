import XCTest
@testable import MVR_Exploder

/// The same invariants, over real show files.
///
/// Skipped unless `MVR_CORPUS` names a folder to sweep, because those are
/// client files: they can't live in the repository, and a suite that fails
/// on a machine without them is a suite people stop running. Point it at a
/// library and it checks every `.mvr` underneath:
///
///     TEST_RUNNER_MVR_CORPUS=~/Documents/shows \
///       xcodebuild -scheme "MVR Exploder" -destination platform=macOS test
///
/// The `TEST_RUNNER_` prefix is not decoration: `xcodebuild` passes only
/// variables named that way through to the test process, stripping the
/// prefix on the way. Set plain `MVR_CORPUS` and every test here silently
/// skips. In Xcode, set it in the scheme's Test action instead.
///
/// This is the net the throwaway harnesses used to be. It tests invariants,
/// not correctness — that the numbering is self-consistent, not that the
/// trusses are the right trusses.
final class RealFileCorpusTests: XCTestCase {

    private func corpus() throws -> [URL] {
        guard let path = ProcessInfo.processInfo.environment["MVR_CORPUS"], !path.isEmpty else {
            throw XCTSkip("Set MVR_CORPUS to a folder of .mvr files to run these.")
        }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let files = FileManager.default
            .enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "mvr" } ?? []
        XCTAssertFalse(files.isEmpty, "no .mvr files under \(root.path)")
        return files.sorted { $0.path < $1.path }
    }

    /// Every fixture gets exactly one ID, and no two share one.
    func testEveryRunNumbersEveryFixtureExactlyOnce() throws {
        try eachFile { url, document, session in
            let assignments = session.plan.assignments
            XCTAssertEqual(
                Set(assignments.map(\.fixtureID)).count, assignments.count,
                "a fixture numbered twice in \(url.lastPathComponent)")
            XCTAssertEqual(
                Set(assignments.map(\.newID)).count, assignments.count,
                "two fixtures share an ID in \(url.lastPathComponent)")
            XCTAssertEqual(
                assignments.count, document.fixtures.count,
                "not every fixture numbered in \(url.lastPathComponent)")
        }
    }

    /// Bars are listed downstage to upstage, so a type's LX numbers read in
    /// order. 104 of 320 types across 49 files failed this once.
    func testBarsAreListedInLXOrder() throws {
        try eachFile { url, _, session in
            for spec in session.displayTypes {
                let numbers = (session.plan.lxNumbersBySpec[spec] ?? []).compactMap { $0 }
                XCTAssertEqual(
                    numbers, numbers.sorted(),
                    "\(session.displayName(for: spec)) listed out of LX order in \(url.lastPathComponent)")
            }
        }
    }

    /// Two loads of one file must number identically.
    func testNumberingIsReproducible() throws {
        try eachFile { url, document, session in
            // The reloaded document has to be *held*: `fixture.id` is a
            // fresh UUID per load, so a session built from one load and
            // keyed against another load's fixtures matches nothing.
            let reloaded = try self.reload(url)
            let second = AutoIDSession(fixtures: reloaded.fixtures)
            XCTAssertEqual(
                self.byUUID(document, session), self.byUUID(reloaded, second),
                "\(url.lastPathComponent) numbers differently on a second load")
        }
    }

    /// Exporting must not lose a fixture, whatever the options.
    func testExportKeepsEveryFixture() throws {
        try eachFile { url, document, _ in
            for includeGeometry in [true, false] {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).mvr")
                defer { try? FileManager.default.removeItem(at: destination) }
                try MVRExporter.export(document, to: destination, options: MVRExportOptions(
                    includeSceneGeometry: includeGeometry,
                    assignLayersByFixtureType: false,
                    replaceAllWithDummyGDTFs: false,
                    cleanupEmptyClassesAndLayers: false))

                let reopened = MVRDocument()
                try reopened.load(from: destination, idFieldName: "FixtureID")
                XCTAssertEqual(
                    reopened.fixtures.count, document.fixtures.count,
                    "\(url.lastPathComponent) lost fixtures with includeSceneGeometry: \(includeGeometry)")
            }
        }
    }

    // MARK: - Helpers

    private func eachFile(
        _ body: (URL, MVRDocument, AutoIDSession) throws -> Void
    ) throws {
        var checked = 0
        for url in try corpus() {
            let document = MVRDocument()
            // A file this app can't open is its own bug, not this test's.
            guard (try? document.load(from: url, idFieldName: "FixtureID")) != nil,
                  !document.fixtures.isEmpty else { continue }
            try body(url, document, AutoIDSession(fixtures: document.fixtures))
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "no readable .mvr files in the corpus")
    }

    private func reload(_ url: URL) throws -> MVRDocument {
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return document
    }

    private func byUUID(_ document: MVRDocument, _ session: AutoIDSession) -> [String: Int] {
        let uuids = Dictionary(
            document.fixtures.map { ($0.id, $0.originalUUID) }, uniquingKeysWith: { first, _ in first })
        return session.plan.assignments.reduce(into: [:]) { result, assignment in
            result[uuids[assignment.fixtureID] ?? assignment.fixtureID] = assignment.newID
        }
    }
}
