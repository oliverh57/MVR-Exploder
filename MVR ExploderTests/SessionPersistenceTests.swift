import XCTest
@testable import MVR_Exploder

/// Corrections made in the tool have to survive an export and a re-open.
final class SessionPersistenceTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    func testAnUntouchedRunWritesNoSessionAtAll() throws {
        let (document, session) = try load()
        session.apply(to: document)
        XCTAssertNil(document.autoIDSession, "a file only looked at should come back unchanged")
    }

    func testCorrectionsComeBackAfterAReopen() throws {
        let (document, session) = try load()
        let spec = session.displayTypes[0]

        session.startingID = 501
        session.gaps = AutoIDGaps(
            betweenGroups: true, groupGap: 10, betweenFixtures: true, fixtureGap: 1)
        session.merge(groupIndices: [0, 1], in: spec)
        session.setName("Front Truss", forGroup: 0, in: spec)
        session.setOrdering(.zigZagRows, forGroup: 0, in: spec)
        session.setStartingID(2001, forGroup: 1, in: spec)
        XCTAssertTrue(session.hasCorrections)

        let before = session.plan.assignments
            .map { "\(uuid(document, $0.fixtureID))=\($0.newID)" }.sorted()

        let resumed = try roundTrip(document, session)

        XCTAssertTrue(resumed.session.restoredFromFile)
        XCTAssertEqual(resumed.session.startingID, 501)
        XCTAssertEqual(resumed.session.gaps.groupGap, 10)
        XCTAssertTrue(resumed.session.gaps.betweenFixtures)

        let spec2 = resumed.session.displayTypes[0]
        XCTAssertEqual(resumed.session.name(forGroup: 0, in: spec2), "Front Truss")
        XCTAssertEqual(resumed.session.ordering(forGroup: 0, in: spec2), .zigZagRows)
        XCTAssertEqual(resumed.session.startingID(forGroup: 1, in: spec2), 2001)

        let after = resumed.session.plan.assignments
            .map { "\(uuid(resumed.document, $0.fixtureID))=\($0.newID)" }.sorted()
        XCTAssertEqual(before, after, "the same file must number the same way after a reopen")
    }

    func testStartingFreshClearsEverythingAndStopsItBeingWrittenBack() throws {
        let (document, session) = try load()
        session.merge(groupIndices: [0, 1], in: session.displayTypes[0])
        let resumed = try roundTrip(document, session)

        resumed.session.startFresh()

        XCTAssertFalse(resumed.session.hasCorrections)
        XCTAssertFalse(resumed.session.restoredFromFile)
        resumed.session.apply(to: resumed.document)
        XCTAssertNil(resumed.document.autoIDSession)
    }

    func testUnsavedWorkIsOnlyFlaggedOnceSomethingChanges() throws {
        let (_, session) = try load()
        XCTAssertFalse(session.hasUnsavedWork, "nothing done yet")

        session.acknowledge(groupIndex: 0, in: session.displayTypes[0])
        XCTAssertFalse(session.hasUnsavedWork, "looking at a group is not work")

        session.merge(groupIndices: [0, 1], in: session.displayTypes[0])
        XCTAssertTrue(session.hasUnsavedWork)

        session.undo()
        XCTAssertTrue(session.hasUnsavedWork, "undoing does not un-do having worked")
    }

    // MARK: - Helpers

    private func load() throws -> (MVRDocument, AutoIDSession) {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Spot", count: 6, y: 0)
                + MVRTestRig.bar("Spot", count: 6, y: 4000)
                + MVRTestRig.bar("Spot", count: 6, y: 8000)
                + MVRTestRig.bar("Wash", count: 5, y: 2000))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return (document, AutoIDSession(fixtures: document.fixtures))
    }

    private func roundTrip(
        _ document: MVRDocument, _ session: AutoIDSession
    ) throws -> (document: MVRDocument, session: AutoIDSession) {
        session.apply(to: document)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mvr")
        try MVRExporter.export(document, to: url, options: MVRExportOptions(
            includeSceneGeometry: true,
            assignLayersByFixtureType: false,
            replaceAllWithDummyGDTFs: false,
            cleanupEmptyClassesAndLayers: false))

        let reopened = MVRDocument()
        try reopened.load(from: url, idFieldName: "FixtureID")
        return (reopened, AutoIDSession(
            fixtures: reopened.fixtures,
            storedNames: reopened.groupNames,
            session: reopened.autoIDSession))
    }

    /// The file's own uuid, since `fixture.id` is per-load.
    private func uuid(_ document: MVRDocument, _ fixtureID: String) -> String {
        document.fixtures.first { $0.id == fixtureID }?.originalUUID ?? fixtureID
    }
}
