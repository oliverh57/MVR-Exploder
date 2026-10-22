import XCTest
import ZIPFoundation
@testable import MVR_Exploder

/// Replacing a fixture type's GDTF with one from GDTF Share: reading the
/// list, finding the right fixture, matching modes, and the swap itself.
/// Nothing here touches the network — signing in needs a real account.
final class GDTFShareTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    private func entry(
        _ rid: Int, _ manufacturer: String, _ fixture: String, uuid: String,
        modified: TimeInterval = 0, uploader: String = "User", rating: Double = 0,
        modes: [(String, Int)] = [("Standard", 10)]
    ) -> GDTFShareEntry {
        GDTFShareEntry(
            rid: rid, manufacturer: manufacturer, fixture: fixture, revision: "r\(rid)",
            lastModified: Date(timeIntervalSince1970: modified), uploader: uploader, rating: rating,
            uuid: uuid, modes: modes.map { GDTFShareEntry.Mode(name: $0.0, footprint: $0.1) })
    }

    /// The documented shape, with the numbers that arrive as strings.
    func testTheListIsReadTolerantly() throws {
        let json = """
        {"result": true, "timestamp": 1700000000, "list": [
          {"rid": 3038, "fixture": "Robin MegaPointe", "manufacturer": "Robe", "revision": "DMX v1.7",
           "creationDate": 1600000000, "lastModified": "1650000000", "uploader": "Manuf.", "rating": "4.5",
           "version": "1.1", "creator": "robe", "uuid": "62249F3B", "filesize": 120000,
           "modes": [{"name": "Mode 1", "dmxfootprint": 34}, {"name": "Mode 2", "dmxfootprint": "39"}]},
          {"fixture": "No rid, so skipped"}
        ]}
        """
        let entries = try GDTFShareClient.parseList(Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        let mega = try XCTUnwrap(entries.first)
        XCTAssertEqual(mega.rid, 3038)
        XCTAssertEqual(mega.rating, 4.5)
        XCTAssertTrue(mega.isFromManufacturer)
        XCTAssertEqual(mega.lastModified.timeIntervalSince1970, 1_650_000_000)
        XCTAssertEqual(mega.modes, [.init(name: "Mode 1", footprint: 34), .init(name: "Mode 2", footprint: 39)])
        XCTAssertEqual(mega.fileName, "Robe@Robin MegaPointe@r3038.gdtf")

        XCTAssertThrowsError(try GDTFShareClient.parseList(Data(#"{"result": false, "error": "Not logged in"}"#.utf8)))
    }

    /// Only the newest revision of each fixture, the manufacturer's own
    /// upload ahead of a user's, and loose enough to find a fixture from a
    /// rig's own spelling of it.
    func testSearchFindsTheBestRevisionFirst() {
        let entries = [
            entry(1, "Robe", "Robin MegaPointe", uuid: "mega", modified: 100, uploader: "Manuf."),
            entry(2, "Robe", "Robin MegaPointe", uuid: "mega", modified: 200, uploader: "Manuf."),
            entry(3, "Someone", "Robin MegaPointe copy", uuid: "copy", modified: 300, rating: 5),
            entry(4, "Martin", "MAC Aura XIP", uuid: "aura"),
            entry(5, "Robe", "Spiider", uuid: "spiider"),
        ]
        let mega = GDTFShareClient.search(entries, for: "Robe Robin MegaPointe")
        XCTAssertEqual(mega.map(\.rid), [2, 3])

        // Three of the four words is enough.
        XCTAssertEqual(GDTFShareClient.search(entries, for: "Martin Aura Raven XIP").map(\.rid), [4])
        XCTAssertEqual(GDTFShareClient.search(entries, for: "  ").map(\.rid), [])
    }

    func testModesAreMatchedByNameThenFootprint() {
        let modes = [GDTFShareEntry.Mode(name: "Standard", footprint: 34), .init(name: "Extended", footprint: 39)]
        XCTAssertEqual(GDTFShareClient.defaultMode(for: "extended", footprint: nil, in: modes), "Extended")
        XCTAssertEqual(GDTFShareClient.defaultMode(for: "DMX Mode", footprint: 39, in: modes), "Extended")
        XCTAssertEqual(GDTFShareClient.defaultMode(for: "DMX Mode", footprint: 12, in: modes), "Standard")
        XCTAssertNil(GDTFShareClient.defaultMode(for: "DMX Mode", footprint: 12, in: []))
    }

    func testTheSearchStartsFromTheTypesOwnName() {
        XCTAssertEqual(GDTFShareClient.suggestedQuery(for: "Robe@Robin MegaPointe [Bulb=Sirius HRI 475W].gdtf"), "Robe Robin MegaPointe")
        // A stand-in's "Custom" isn't a manufacturer worth searching for.
        XCTAssertFalse(GDTFShareClient.suggestedQuery(for: "Custom@PM_Light_Martin_Aura_Raven_XIP.gdtf").contains("Custom"))
    }

    // MARK: - The swap

    /// A minimal .gdtf: a zip holding a description with two modes.
    private func gdtf() throws -> Data {
        let description = """
        <GDTF DataVersion="1.1"><FixtureType Name="Spot" Manufacturer="Robe"><DMXModes>
          <DMXMode Name="Mode 1"><DMXChannels>
            <DMXChannel DMXBreak="1" Offset="1"><LogicalChannel Attribute="Dimmer"/></DMXChannel>
            <DMXChannel DMXBreak="1" Offset="2,3"><LogicalChannel Attribute="Pan"/></DMXChannel>
          </DMXChannels></DMXMode>
          <DMXMode Name="Mode 2"><DMXChannels>
            <DMXChannel DMXBreak="1" Offset="1"><LogicalChannel Attribute="Dimmer"/></DMXChannel>
          </DMXChannels></DMXMode>
        </DMXModes></FixtureType></GDTF>
        """
        let archive = try Archive(accessMode: .create)
        let data = Data(description.utf8)
        try archive.addEntry(
            with: "description.xml", type: .file, uncompressedSize: Int64(data.count),
            provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
        return try XCTUnwrap(archive.data)
    }

    func testReplacingAGDTFMovesTheTypeAndItsModesAndUndoes() async throws {
        let url = try MVRTestRig.write(
            MVRTestRig.bar("Stand-in Spot", count: 3, y: 0) + MVRTestRig.bar("Wash", count: 2, y: 2000))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo

        let data = try gdtf()
        undo.beginUndoGrouping()
        document.replaceGDTF("Stand-in Spot.gdtf", withFile: "Robe@Spot@r42.gdtf", data: data, modes: ["Standard": "Mode 1"])
        undo.endUndoGrouping()

        let spots = document.fixtures.filter { $0.name.hasPrefix("Stand-in Spot") }
        XCTAssertEqual(Set(spots.map(\.gdtfSpec)), ["Robe@Spot@r42.gdtf"])
        XCTAssertEqual(Set(spots.map(\.mode)), ["Mode 1"])
        XCTAssertEqual(Set(document.fixtures.filter { $0.name.hasPrefix("Wash") }.map(\.gdtfSpec)), ["Wash.gdtf"])
        XCTAssertTrue(document.editTags.contains("GDTF"))

        // The rest of the app reads the new GDTF: its modes, and its file.
        let footprints = await document.loadFootprints()
        XCTAssertEqual(footprints["Robe@Spot@r42.gdtf"]?.map(\.mode), ["Mode 1", "Mode 2"])
        XCTAssertEqual(footprints["Robe@Spot@r42.gdtf"]?.first?.parameters, 2)
        XCTAssertEqual(document.gdtfFileData(forSpec: "Robe@Spot@r42.gdtf"), data)

        // Export carries it, and the fixtures point at it.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("gdtf-share-\(UUID().uuidString).mvr")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        try MVRExporter.export(document, to: out, options: MVRExportOptions(
            includeSceneGeometry: true, assignLayersByFixtureType: false,
            replaceAllWithDummyGDTFs: false, cleanupEmptyClassesAndLayers: false))
        let archive = try Archive(url: out, accessMode: .read)
        let entry = try XCTUnwrap(archive["Robe@Spot@r42.gdtf"])
        var written = Data()
        _ = try archive.extract(entry) { written.append($0) }
        XCTAssertEqual(written, data)
        let file = try MVRDocument.read(from: out)
        let specs = try file.xml.nodes(forXPath: "//Fixture/GDTFSpec").compactMap(\.stringValue)
        XCTAssertEqual(specs.filter { $0 == "Robe@Spot@r42.gdtf" }.count, 3)

        undo.undo()
        XCTAssertEqual(Set(document.fixtures.filter { $0.name.hasPrefix("Stand-in Spot") }.map(\.gdtfSpec)), ["Stand-in Spot.gdtf"])
        XCTAssertEqual(Set(document.fixtures.map(\.mode)), ["Standard"])
        XCTAssertNil(document.injectedGDTFFiles["Robe@Spot@r42.gdtf"])

        undo.redo()
        XCTAssertEqual(Set(document.fixtures.filter { $0.name.hasPrefix("Stand-in Spot") }.map(\.mode)), ["Mode 1"])
        XCTAssertNotNil(document.injectedGDTFFiles["Robe@Spot@r42.gdtf"])
    }

    // MARK: - Telling genuine from stand-in

    private func description(manufacturer: String, about: String = "", channels: [(String, String)]) throws -> XMLDocument {
        let list = channels.map { "<DMXChannel DMXBreak=\"1\" Offset=\"\($0.1)\"><LogicalChannel Attribute=\"\($0.0)\"/></DMXChannel>" }.joined()
        return try XMLDocument(xmlString: """
        <GDTF><FixtureType Name="T" Manufacturer="\(manufacturer)" Description="\(about)"><DMXModes>
          <DMXMode Name="DMX Mode"><DMXChannels>\(list)</DMXChannels></DMXMode>
        </DMXModes></FixtureType></GDTF>
        """)
    }

    /// The stand-ins real files carry: Vectorworks' "Custom" GDTFs, this
    /// app's own dummies, and modes filled with "NoFeature".
    func testStandInGDTFsAreRecognised() throws {
        let real = [("Dimmer", "1"), ("Pan", "2,3"), ("Tilt", "4,5")]
        XCTAssertFalse(GDTFFootprintParser.modes(description: try description(manufacturer: "Robe", channels: real))[0].isPlaceholder)

        XCTAssertTrue(GDTFFootprintParser.modes(description: try description(manufacturer: "Custom", channels: real))[0].isPlaceholder)
        XCTAssertTrue(GDTFFootprintParser.modes(description: try description(
            manufacturer: "MVR Exploder", about: "Placeholder GDTF generated by MVR Exploder", channels: [("Dimmer", "1")]))[0].isPlaceholder)

        let mostlyNothing = (1...10).map { ("NoFeature", String($0)) } + [("Dimmer", "11")]
        XCTAssertTrue(GDTFFootprintParser.modes(description: try description(manufacturer: "Martin", channels: mostlyNothing))[0].isPlaceholder)
    }

    func testGDTFShareNamesAreRecognised() {
        XCTAssertTrue(ModeViewerView.isGDTFShareName("Robe Lighting@Robin iForte LTX WB@r12345.gdtf"))
        XCTAssertFalse(ModeViewerView.isGDTFShareName("Custom@PM_Light_GLP_JDC_Burst_1.gdtf"))
        XCTAssertFalse(ModeViewerView.isGDTFShareName("Robe@Robin iForte [Bulb=LED].gdtf"))
    }

    /// What makes a type "verified" is a record of where its GDTF came
    /// from; it has to survive saving and reopening, and go with an undo.
    func testTheGDTFShareRecordSurvivesExportAndUndo() throws {
        let url = try MVRTestRig.write(MVRTestRig.bar("Stand-in Spot", count: 2, y: 0))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo

        let source = MVRUserData.GDTFSource(
            rid: 42, manufacturer: "Robe", fixture: "Spot", revision: "DMX v1.2",
            uploader: "Manuf.", modified: Date(timeIntervalSince1970: 1_700_000_000))
        undo.beginUndoGrouping()
        document.replaceGDTF("Stand-in Spot.gdtf", withFile: "Robe@Spot@r42.gdtf", data: try gdtf(),
                             modes: ["Standard": "Mode 1"], source: source)
        undo.endUndoGrouping()
        XCTAssertEqual(document.gdtfSources["Robe@Spot@r42.gdtf"], source)

        func exportAndReopen() throws -> MVRDocument {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("record-\(UUID().uuidString).mvr")
            addTeardownBlock { try? FileManager.default.removeItem(at: out) }
            try MVRExporter.export(document, to: out, options: MVRExportOptions(
                includeSceneGeometry: true, assignLayersByFixtureType: false,
                replaceAllWithDummyGDTFs: false, cleanupEmptyClassesAndLayers: false))
            let reopened = MVRDocument()
            try reopened.load(from: out, idFieldName: "FixtureID")
            return reopened
        }
        XCTAssertEqual(try exportAndReopen().gdtfSources, ["Robe@Spot@r42.gdtf": source])

        undo.undo()
        XCTAssertTrue(document.gdtfSources.isEmpty)
        XCTAssertTrue(try exportAndReopen().gdtfSources.isEmpty)
        undo.redo()
        XCTAssertEqual(document.gdtfSources["Robe@Spot@r42.gdtf"], source)
    }
}
