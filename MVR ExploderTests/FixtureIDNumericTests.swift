import XCTest
import ZIPFoundation
@testable import MVR_Exploder

/// grandMA3 writes a fixture's ID twice — `<FixtureID>` and
/// `<FixtureIDNumeric>` — and reads the numeric one back. Offsetting only
/// the string once sent a file into MA at its old IDs, 1000s instead of
/// 40000s, while this app showed the new ones.
final class FixtureIDNumericTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    private let maElements = ["FixtureID", "FixtureIDNumeric"]

    func testOffsetReachesTheNumericID() throws {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Spot", count: 4, y: 0, idsFrom: 1001), idElements: maElements)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")

        document.applyFixtureIDOffset(39000)

        let ids = try exportedIDs(of: document)
        XCTAssertEqual(ids.map(\.fixtureID), [40001, 40002, 40003, 40004])
        XCTAssertEqual(ids.map(\.numeric), ids.map(\.fixtureID))
    }

    func testSingleEditAndResetReachTheNumericID() throws {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 1001), idElements: maElements)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")

        let first = document.fixtures[0].id
        document.setFixtureID(500, forFixtureAtID: first)
        XCTAssertEqual(try exportedIDs(of: document).map(\.numeric), [500, 1002])

        document.resetField(.fixtureID, forFixtureAtID: first)
        XCTAssertEqual(try exportedIDs(of: document).map(\.numeric), [1001, 1002])
    }

    func testUnitNumberFileKeepsTheNumericIDInStep() throws {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 7), idElements: ["UnitNumber", "FixtureIDNumeric"])
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "UnitNumber")

        document.applyFixtureIDOffset(100)

        let ids = try exportedIDs(of: document)
        XCTAssertEqual(ids.map(\.fixtureID), [107, 108])
        XCTAssertEqual(ids.map(\.numeric), [107, 108])
    }

    func testFileWithOnlyANumericIDStillLoadsAndExports() throws {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Spot", count: 2, y: 0, idsFrom: 1001), idElements: ["FixtureIDNumeric"])
        guard case .determined("FixtureID") = MVRDocument.detectIDField(at: url) else {
            return XCTFail("a numeric-only ID should still detect as FixtureID")
        }

        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        XCTAssertEqual(document.fixtures.map(\.currentFixtureID), [1001, 1002])

        document.applyFixtureIDOffset(39000)
        let ids = try exportedIDs(of: document)
        XCTAssertEqual(ids.map(\.fixtureID), [40001, 40002])
        XCTAssertEqual(ids.map(\.numeric), [40001, 40002])
    }

    // MARK: - Helpers

    /// Both ID elements of every fixture in an export, read straight from
    /// the XML — what a console sees, not what the app thinks it wrote.
    private func exportedIDs(of document: MVRDocument) throws -> [(fixtureID: Int?, numeric: Int?)] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mvr")
        defer { try? FileManager.default.removeItem(at: url) }
        try MVRExporter.export(document, to: url, options: MVRExportOptions(
            includeSceneGeometry: true,
            assignLayersByFixtureType: false,
            replaceAllWithDummyGDTFs: false,
            cleanupEmptyClassesAndLayers: false))

        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive["GeneralSceneDescription.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let xml = try XMLDocument(data: data, options: [])

        return try xml.nodes(forXPath: "//Fixture").compactMap { $0 as? XMLElement }.map { fixture in
            func value(_ name: String) -> Int? {
                fixture.elements(forName: name).first?.stringValue.flatMap { Int($0) }
            }
            return (value("FixtureID"), value("FixtureIDNumeric"))
        }
    }
}
