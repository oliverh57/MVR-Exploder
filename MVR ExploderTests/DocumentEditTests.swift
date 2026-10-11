import XCTest
@testable import MVR_Exploder

/// Edits reaching the exported file, and coming back out with undo.
final class DocumentEditTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    private func open(_ fixtures: [MVRTestRig.Fixture]) throws -> (MVRDocument, URL) {
        let url = try MVRTestRig.write(fixtures)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return (document, url)
    }

    private func exportAndReopen(_ document: MVRDocument, to url: URL? = nil) throws -> MVRDocument {
        let destination = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mvr")
        try MVRExporter.export(document, to: destination, options: MVRExportOptions(
            includeSceneGeometry: true,
            assignLayersByFixtureType: false,
            replaceAllWithDummyGDTFs: false,
            cleanupEmptyClassesAndLayers: false))
        let reopened = MVRDocument()
        try reopened.load(from: destination, idFieldName: "FixtureID")
        return reopened
    }

    // MARK: - Export

    /// Saving over the file that was opened used to delete it before it
    /// was read from, and the export failed with the original gone.
    func testExportingOverTheOpenFileKeepsIt() throws {
        let (document, url) = try open(MVRTestRig.bar("Spot", count: 3, y: 0, idsFrom: 1))
        document.setName("Renamed", forFixtureAtID: document.fixtures[0].id)

        let reopened = try exportAndReopen(document, to: url)

        XCTAssertEqual(reopened.fixtures.count, 3)
        XCTAssertTrue(reopened.fixtures.contains { $0.name == "Renamed" })
    }

    /// grandMA3 writes the ID into <FixtureIDNumeric> as well as
    /// <FixtureID>, and reads it back from there. A renumber used to leave
    /// the numeric copy at the old value, so MA3 imported the original IDs.
    func testRenumberingUpdatesFixtureIDNumeric() throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 101))
        for fixture in document.fixtures {
            fixture.xmlElement.addChild(XMLElement(
                name: "FixtureIDNumeric", stringValue: String(fixture.currentFixtureID!)))
        }
        document.setFixtureIDs(Dictionary(uniqueKeysWithValues: document.fixtures.map {
            ($0.id, $0.currentFixtureID! + 44000)
        }))

        let reopened = try exportAndReopen(document)

        let numeric = reopened.fixtures.compactMap {
            $0.xmlElement.elements(forName: "FixtureIDNumeric").first?.stringValue
        }
        XCTAssertEqual(numeric.sorted(), ["44101", "44102"])
    }

    // MARK: - Fixtures with no ID

    /// A fixture with no `<FixtureID>` showed its new number in the app
    /// and lost it on export.
    func testANewIDOnAnUnnumberedFixtureIsExported() throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 3, y: 0))
        XCTAssertTrue(document.fixtures.allSatisfy { $0.currentFixtureID == nil })

        document.setFixtureIDs(Dictionary(uniqueKeysWithValues:
            document.fixtures.enumerated().map { ($1.id, 101 + $0) }))

        let reopened = try exportAndReopen(document)
        XCTAssertEqual(Set(reopened.fixtures.compactMap(\.currentFixtureID)), [101, 102, 103])
    }

    func testResettingANewIDTakesItAwayAgain() throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 1, y: 0))
        let id = document.fixtures[0].id
        document.setFixtureID(7, forFixtureAtID: id)

        document.resetField(.fixtureID, forFixtureAtID: id)

        XCTAssertNil(document.fixtures[0].currentFixtureID)
        XCTAssertNil(try exportAndReopen(document).fixtures[0].currentFixtureID)
    }

    // MARK: - Drafts

    /// A tool's edits go to its copy; the file stays as it was until Apply.
    func testADraftsEditsStayOutOfTheFileUntilApplied() async throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 3, y: 0, idsFrom: 1))
        let made = await document.makeDraft()
        let draft = try XCTUnwrap(made)
        let first = document.fixtures[0].id

        draft.setName("Renamed", forFixtureAtID: first)
        draft.deleteFixture(withID: document.fixtures[2].id)
        draft.applyFixtureIDOffset(100)

        XCTAssertEqual(document.fixtures.count, 3)
        XCTAssertEqual(document.fixtures.compactMap(\.currentFixtureID), [1, 2, 3])
        XCTAssertFalse(document.hasUnexportedChanges)
        let untouched = try exportAndReopen(document)
        XCTAssertEqual(untouched.fixtures.count, 3, "the file's XML wasn't touched either")
        XCTAssertFalse(untouched.fixtures.contains { $0.name == "Renamed" })

        document.adopt(draft, as: "Edit")

        XCTAssertEqual(document.fixtures.count, 2)
        XCTAssertEqual(document.fixtures.first { $0.id == first }?.name, "Renamed", "same ids")
        XCTAssertTrue(document.hasUnexportedChanges)
        let applied = try exportAndReopen(document)
        XCTAssertEqual(applied.fixtures.count, 2)
        XCTAssertEqual(Set(applied.fixtures.compactMap(\.currentFixtureID)), [101, 102])
    }

    func testANewPatchInADraftLandsInItsOwnCopy() async throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 1, y: 0))
        let made = await document.makeDraft()
        let draft = try XCTUnwrap(made)

        draft.setAddress(600, forFixtureAtID: document.fixtures[0].id)

        XCTAssertEqual(document.fixtures[0].currentAddress, 1)
        XCTAssertEqual(try exportAndReopen(document).fixtures[0].currentAddress, 1)
        document.adopt(draft, as: "Edit")
        XCTAssertEqual(try exportAndReopen(document).fixtures[0].currentAddress, 600)
    }

    func testADraftWithNoEditsChangesNothingWhenApplied() async throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 1))
        let made = await document.makeDraft()
        let draft = try XCTUnwrap(made)
        XCTAssertEqual(draft.editCount, 0)

        document.adopt(draft, as: "Edit")

        XCTAssertFalse(document.hasUnexportedChanges)
    }

    // MARK: - Export name

    private let plainExport = MVRExportOptions(
        includeSceneGeometry: true, assignLayersByFixtureType: false,
        replaceAllWithDummyGDTFs: false, cleanupEmptyClassesAndLayers: false)

    /// The exported file is named after what was done to it, in order.
    func testTheExportIsNamedAfterWhatWasDone() async throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 1))

        let session = AutoIDSession(fixtures: document.fixtures)
        session.apply(to: document)

        let made = await document.makeDraft()
        let draft = try XCTUnwrap(made)
        draft.applyFixtureIDOffset(100)
        document.adopt(draft, as: "Edit")

        XCTAssertEqual(plainExport.exportName(for: document.fileName, editTags: document.editTags),
                       "\((document.fileName as NSString).deletingPathExtension)_AutoID_IDOffset")
    }

    /// A tool whose work has no name of its own is named after the tool.
    func testAToolsTagIsUsedWhenItRecordedNothingMoreSpecific() async throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 1))
        let made = await document.makeDraft()
        let draft = try XCTUnwrap(made)
        draft.setName("Renamed", forFixtureAtID: document.fixtures[0].id)
        document.adopt(draft, as: "ModeSwap")
        XCTAssertEqual(document.editTags, ["ModeSwap"])
    }

    func testExportOptionsAddToTheName() {
        var options = plainExport
        XCTAssertEqual(options.exportName(for: "Show.mvr", editTags: []), "Show_edited")
        options.includeSceneGeometry = false
        XCTAssertEqual(options.exportName(for: "Show.mvr", editTags: ["AutoID"]), "Show_AutoID_GeomCleanup")
    }

    // MARK: - Undo

    private func undoable(_ document: MVRDocument) -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        document.undoManager = manager
        return manager
    }

    private func step(_ manager: UndoManager, _ edit: () -> Void) {
        manager.beginUndoGrouping()
        edit()
        manager.endUndoGrouping()
    }

    func testABatchOfIDsUndoesInOneStep() throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 3, y: 0, idsFrom: 1))
        let manager = undoable(document)

        step(manager) { document.applyFixtureIDOffset(100) }
        XCTAssertEqual(document.fixtures.compactMap(\.currentFixtureID), [101, 102, 103])

        manager.undo()
        XCTAssertEqual(document.fixtures.compactMap(\.currentFixtureID), [1, 2, 3])
        XCTAssertFalse(manager.canUndo)

        manager.redo()
        XCTAssertEqual(document.fixtures.compactMap(\.currentFixtureID), [101, 102, 103])
    }

    func testUndoingADeletePutsTheFixtureBackInTheFile() throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 3, y: 0, idsFrom: 1))
        let manager = undoable(document)
        let names = document.fixtures.map(\.name)

        step(manager) { document.deleteFixture(withID: document.fixtures[1].id) }
        XCTAssertEqual(document.fixtures.count, 2)

        manager.undo()
        XCTAssertEqual(document.fixtures.map(\.name), names, "back in its place")
        XCTAssertEqual(try exportAndReopen(document).fixtures.map(\.name), names, "and in the XML")

        manager.redo()
        XCTAssertEqual(document.fixtures.count, 2)
    }

    func testUndoingAPatchChangePutsTheOldAddressBack() throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 1, y: 0))
        let manager = undoable(document)

        step(manager) { document.applyUniverseOffset(1) }
        XCTAssertEqual(document.fixtures[0].currentAddress, 513)
        manager.undo()

        XCTAssertEqual(document.fixtures[0].currentAddress, 1)
        XCTAssertEqual(try exportAndReopen(document).fixtures[0].currentAddress, 1)
    }

    func testUndoingAMergeTakesTheFixturesBackOut() throws {
        let (a, _) = try open(MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 1))
        let (b, _) = try open(MVRTestRig.bar("Wash", count: 2, y: 3000, idsFrom: 11))
        let manager = undoable(a)

        step(manager) { a.importFixtures(withIDs: b.fixtures.map(\.id), from: b) }
        XCTAssertEqual(a.fixtures.count, 4)

        manager.undo()
        XCTAssertEqual(a.fixtures.count, 2)
        XCTAssertEqual(try exportAndReopen(a).fixtures.count, 2)
    }

    func testOpeningAFileClearsUndo() throws {
        let (document, _) = try open(MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 1))
        let manager = undoable(document)
        step(manager) { document.applyFixtureIDOffset(1) }

        try document.load(from: MVRTestRig.write(MVRTestRig.bar("Wash", count: 1, y: 0)),
                          idFieldName: "FixtureID")

        XCTAssertFalse(manager.canUndo)
    }
}
