import XCTest
@testable import MVR_Exploder

/// Bringing fixtures from a second file into the open one — Compare
/// mode's merge, B into A.
final class MergeTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    private func open(
        _ fixtures: [MVRTestRig.Fixture],
        layer: String = "Lighting",
        layerUUID: String = "11111111-2222-3333-4444-555555555555"
    ) throws -> MVRDocument {
        let url = try MVRTestRig.write(fixtures, layer: layer, layerUUID: layerUUID)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return document
    }

    func testImportedFixturesArriveWithTheirValues() throws {
        let a = try open(MVRTestRig.bar("Spot", count: 3, y: 0, idsFrom: 101))
        let b = try open(MVRTestRig.bar("Wash", count: 2, y: 3000, idsFrom: 201))

        let added = a.importFixtures(withIDs: b.fixtures.map(\.id), from: b)

        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(a.fixtures.count, 5)
        let arrived = a.fixtures.filter { added.contains($0.id) }
        XCTAssertEqual(arrived.map(\.name), ["Wash 1", "Wash 2"])
        XCTAssertEqual(arrived.map(\.currentFixtureID), [201, 202])
        XCTAssertEqual(arrived.map(\.gdtfSpec), ["Wash.gdtf", "Wash.gdtf"])
        XCTAssertEqual(Set(arrived.map(\.currentUUID)), Set(b.fixtures.map(\.currentUUID)),
                       "nothing clashed, so the UUIDs came across as they were")
    }

    /// Only the selected ones come over.
    func testOnlyTheAskedForFixturesArrive() throws {
        let a = try open(MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 101))
        let b = try open(MVRTestRig.bar("Wash", count: 4, y: 3000, idsFrom: 201))

        a.importFixtures(withIDs: [b.fixtures[1].id, b.fixtures[3].id], from: b)

        XCTAssertEqual(a.fixtures.count, 4)
        XCTAssertEqual(a.fixtures.suffix(2).map(\.name), ["Wash 2", "Wash 4"])
    }

    /// Two fixtures sharing a UUID is a broken file, so the incoming one
    /// gets a new one. That's the Fixture-ID-matched case: matched on UUID,
    /// a fixture only in B has a UUID A hasn't got by definition.
    func testAClashingUUIDIsReplaced() throws {
        let shared = UUID().uuidString
        let a = try open([MVRTestRig.Fixture(name: "Spot 1", type: "Spot", id: 101,
                                             x: 0, y: 0, z: 8000, uuid: shared)])
        let b = try open([
            MVRTestRig.Fixture(name: "Wash 1", type: "Wash", id: 101, x: 0, y: 0, z: 8000, uuid: shared),
            MVRTestRig.Fixture(name: "Wash 2", type: "Wash", id: 102, x: 1500, y: 0, z: 8000),
        ])

        let added = a.importFixtures(withIDs: b.fixtures.map(\.id), from: b)
        let arrived = a.fixtures.filter { added.contains($0.id) }

        XCTAssertNotEqual(arrived[0].currentUUID.lowercased(), shared.lowercased())
        XCTAssertEqual(arrived[1].currentUUID, b.fixtures[1].currentUUID, "no clash, kept")
        XCTAssertEqual(Set(a.fixtures.map { $0.currentUUID.lowercased() }).count, a.fixtures.count,
                       "every UUID in A is unique")
        XCTAssertEqual(arrived[0].currentFixtureID, 101,
                       "the clashing Fixture ID is left for the user to see, not renumbered")
    }

    /// A layer A hasn't got is made; A's own layers are left exactly as
    /// they were.
    func testAMissingLayerIsMadeAndAsLayersAreLeftAlone() throws {
        let a = try open(MVRTestRig.bar("Spot", count: 1, y: 0), layer: "Lighting",
                         layerUUID: "aaaaaaaa-0000-0000-0000-000000000001")
        let b = try open(MVRTestRig.bar("Wash", count: 1, y: 0), layer: "Truss",
                         layerUUID: "bbbbbbbb-0000-0000-0000-000000000002")

        let added = a.importFixtures(withIDs: b.fixtures.map(\.id), from: b)
        let arrived = try XCTUnwrap(a.fixtures.first { added.contains($0.id) })

        XCTAssertEqual(arrived.layerName, "Truss")
        XCTAssertEqual(arrived.layerUUID, "bbbbbbbb-0000-0000-0000-000000000002")
        let lighting = try XCTUnwrap(a.availableLayers.first { $0.name == "Lighting" })
        XCTAssertEqual(lighting.uuid, "aaaaaaaa-0000-0000-0000-000000000001")
        XCTAssertEqual(a.availableLayers.count, 2)
    }

    /// A layer A already has by UUID is used as it is — not renamed to
    /// whatever B called it.
    func testALayerAlreadyInAIsUsedWithoutRenaming() throws {
        let a = try open(MVRTestRig.bar("Spot", count: 1, y: 0), layer: "Lighting")
        let b = try open(MVRTestRig.bar("Wash", count: 1, y: 0), layer: "Truss")

        let added = a.importFixtures(withIDs: b.fixtures.map(\.id), from: b)
        let arrived = try XCTUnwrap(a.fixtures.first { added.contains($0.id) })

        XCTAssertEqual(arrived.layerName, "Lighting")
        XCTAssertEqual(a.availableLayers.map(\.name), ["Lighting"])
    }

    /// The test that matters: merged fixtures are really in the file.
    func testMergedFixturesSurviveExport() throws {
        let a = try open(MVRTestRig.bar("Spot", count: 3, y: 0, idsFrom: 101))
        let b = try open(MVRTestRig.bar("Wash", count: 2, y: 3000, idsFrom: 201),
                         layer: "Truss", layerUUID: "bbbbbbbb-0000-0000-0000-000000000002")
        a.importFixtures(withIDs: b.fixtures.map(\.id), from: b)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVRExploderTests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).mvr")
        try MVRExporter.export(a, to: url, options: MVRExportOptions(
            includeSceneGeometry: true, assignLayersByFixtureType: false,
            replaceAllWithDummyGDTFs: false, cleanupEmptyClassesAndLayers: false))

        let reopened = MVRDocument()
        try reopened.load(from: url, idFieldName: "FixtureID")
        XCTAssertEqual(reopened.fixtures.count, 5)
        XCTAssertEqual(Set(reopened.fixtures.compactMap(\.currentFixtureID)),
                       [101, 102, 103, 201, 202])
        XCTAssertEqual(reopened.fixtures.filter { $0.layerName == "Truss" }.count, 2)
    }
}

/// Whether the open file has edits nobody has exported yet.
final class UnexportedChangesTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    private func open() throws -> MVRDocument {
        let url = try MVRTestRig.write(MVRTestRig.bar("Spot", count: 3, y: 0, idsFrom: 101))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return document
    }

    func testAFreshlyOpenedFileIsClean() throws {
        XCTAssertFalse(try open().hasUnexportedChanges)
    }

    func testAnEditMarksItAndAnExportClearsIt() throws {
        let document = try open()
        document.setName("Renamed", forFixtureAtID: document.fixtures[0].id)
        XCTAssertTrue(document.hasUnexportedChanges)

        document.markExported()
        XCTAssertFalse(document.hasUnexportedChanges)
    }

    /// Every kind of edit, not just the field setters: offsets, deletes and
    /// an Auto ID run's names all count.
    func testEveryKindOfEditCounts() throws {
        let edits: [(String, (MVRDocument) -> Void)] = [
            ("offset", { $0.applyFixtureIDOffset(100) }),
            ("universe offset", { $0.applyUniverseOffset(1) }),
            ("delete", { $0.deleteFixture(withID: $0.fixtures[0].id) }),
            ("new UUIDs", { $0.generateNewUUIDs() }),
            ("group names", { $0.setGroupNames([:]) }),
        ]
        for (name, edit) in edits {
            let document = try open()
            edit(document)
            XCTAssertTrue(document.hasUnexportedChanges, name)
        }
    }

    func testClosingTheFileClearsIt() throws {
        let document = try open()
        document.applyFixtureIDOffset(5)
        document.clear()
        XCTAssertFalse(document.hasUnexportedChanges)
        XCTAssertFalse(document.isLoaded)
    }

    func testReopeningClearsIt() throws {
        let document = try open()
        document.applyFixtureIDOffset(5)
        let url = try MVRTestRig.write(MVRTestRig.bar("Wash", count: 2, y: 0))
        try document.load(from: url, idFieldName: "FixtureID")
        XCTAssertFalse(document.hasUnexportedChanges)
    }
}
