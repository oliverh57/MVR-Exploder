import XCTest
import PDFKit
import SceneKit
@testable import MVR_Exploder

/// The render of the rig that leads the patch PDF.
final class StageRenderTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    private func open(_ fixtures: [MVRTestRig.Fixture]) throws -> MVRDocument {
        let url = try MVRTestRig.write(fixtures)
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        return document
    }

    private func scratchURL(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVRExploderTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    /// Pixels carrying a fixture's tint, which the grey floor and dark
    /// background never have.
    private func tintedPixels(_ image: NSImage) throws -> Int {
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var tinted = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.25 { tinted += 1 }
            }
        }
        return tinted
    }

    /// Leaving a layer out takes its fixtures out of the picture.
    func testAHiddenLayerLeavesItsFixturesOut() throws {
        let document = try open(MVRTestRig.bar("Spot", count: 8, y: 0, idsFrom: 101))
        let stage = try XCTUnwrap(StageScene(document: document, geometry: nil))
        XCTAssertEqual(stage.layers.map(\.name), ["Lighting"])
        XCTAssertEqual(stage.layers.first?.fixtureCount, 8)

        let size = CGSize(width: 400, height: 250)
        XCTAssertGreaterThan(try tintedPixels(stage.render(.front, size: size)), 20)

        var shot = StageScene.Shot.front
        shot.hiddenLayers = [stage.layers[0].id]
        XCTAssertEqual(try tintedPixels(stage.render(shot, size: size)), 0)
    }

    /// The camera moves: from the side, a bar across the stage is end-on
    /// and covers far less of the frame than from the front.
    func testTheCameraGoesWhereItIsTold() throws {
        let document = try open(MVRTestRig.bar("Spot", count: 8, y: 0, idsFrom: 101))
        let stage = try XCTUnwrap(StageScene(document: document, geometry: nil))
        let size = CGSize(width: 400, height: 250)

        let front = try tintedPixels(stage.render(.front, size: size))
        var side = StageScene.Shot.front
        side.azimuth = 90
        let fromTheSide = try tintedPixels(stage.render(side, size: size))

        XCTAssertGreaterThan(front, 0)
        XCTAssertGreaterThan(fromTheSide, 0)
        XCTAssertNotEqual(front, fromTheSide)
    }

    /// The reported bug: the picture lagged a move behind, so the preview
    /// showed the angle before the one asked for. The same shot, taken
    /// either side of a different one, has to come out the same.
    func testEachRenderShowsTheShotAskedForNotThePreviousOne() throws {
        let document = try open(MVRTestRig.bar("Spot", count: 8, y: 0, idsFrom: 101))
        let stage = try XCTUnwrap(StageScene(document: document, geometry: nil))
        let size = CGSize(width: 400, height: 250)
        var side = StageScene.Shot.front
        side.azimuth = 90

        let first = try tintedPixels(stage.render(.front, size: size))
        let between = try tintedPixels(stage.render(side, size: size))
        let again = try tintedPixels(stage.render(.front, size: size))

        // Not pixel-identical — the ambient occlusion carries a little
        // from frame to frame — but the second front shot has to look like
        // the front, not like the side view taken just before it.
        XCTAssertNotEqual(first, between)
        XCTAssertLessThan(abs(again - first), abs(again - between),
                          "front \(first), side \(between), front again \(again)")
    }

    /// "Only render lighting fixtures" takes every piece of scene geometry
    /// out and leaves the fixtures alone.
    func testFixturesOnlyLeavesTheGeometryOutAndTheFixturesIn() throws {
        let document = try open(MVRTestRig.bar("Spot", count: 8, y: 0, idsFrom: 101))

        // A stage under the rig, bright blue so it can be counted.
        let deck = MVRTestRig.boxNode(
            name: "deck", width: 12, height: 1, length: 5, at: SCNVector3(0, 3, 0))
        let blue = SCNMaterial()
        blue.diffuse.contents = NSColor.blue
        blue.emission.contents = NSColor.blue
        deck.geometry?.materials = [blue]
        let layer = SCNNode()
        layer.name = "stage-layer"
        layer.addChildNode(deck)
        let root = SCNNode()
        root.addChildNode(layer)
        let geometry = MVRSceneGeometryLoader.LoadedGeometry(node: root, layers: [], objects: [])

        let stage = try XCTUnwrap(StageScene(document: document, geometry: geometry))
        let size = CGSize(width: 400, height: 250)

        func blueAndTinted(_ shot: StageScene.Shot) throws -> (blue: Int, fixtures: Int) {
            let image = stage.render(shot, size: size)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            var blue = 0
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.blueComponent > c.redComponent + 0.3, c.blueComponent > c.greenComponent + 0.3 {
                        blue += 1
                    }
                }
            }
            return (blue, try tintedPixels(image))
        }

        let everything = try blueAndTinted(.front)
        var only = StageScene.Shot.front
        only.fixturesOnly = true
        let fixturesOnly = try blueAndTinted(only)

        XCTAssertGreaterThan(everything.blue, 50, "the stage is in the normal render")
        XCTAssertEqual(fixturesOnly.blue, 0, "and gone with fixtures only")
        XCTAssertGreaterThan(fixturesOnly.fixtures - fixturesOnly.blue, 20, "the fixtures are still there")
    }

    func testFixturesOnlyIsOffByDefault() {
        XCTAssertFalse(StageScene.Shot.front.fixturesOnly)
    }

    /// The reported bug: after moving the camera round — through the top
    /// view especially — "Front" came back tipped on its side, so Reset
    /// didn't reset. The same shot must give the same picture whatever
    /// came before it.
    func testTheSameShotGivesTheSamePictureWhateverCameBefore() throws {
        var rig = MVRTestRig.bar("Spot", count: 8, y: 0, idsFrom: 101)
        rig += MVRTestRig.bar("Wash", count: 6, y: 4000, z: 6000, idsFrom: 201)
        let document = try open(rig)
        let stage = try XCTUnwrap(StageScene(document: document, geometry: nil))
        let size = CGSize(width: 300, height: 190)

        let fresh = stage.render(.front, size: size)
        var wander = StageScene.Shot.front
        for (azimuth, elevation) in [(0.0, 85.0), (120.0, 85.0), (-60.0, 45.0), (170.0, 10.0)] {
            wander.azimuth = azimuth
            wander.elevation = elevation
            _ = stage.render(wander, size: size)
        }
        let again = stage.render(.front, size: size)

        let a = try XCTUnwrap(fresh.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let b = try XCTUnwrap(again.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var differing = 0, total = 0
        for x in stride(from: 0, to: a.pixelsWide, by: 2) {
            for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                let delta = max(abs(p.redComponent - q.redComponent),
                                abs(p.greenComponent - q.greenComponent),
                                abs(p.blueComponent - q.blueComponent))
                if delta > 0.15 { differing += 1 }
            }
        }
        // Ambient occlusion moves a few pixels between renders; a turned
        // camera moves most of them.
        XCTAssertLessThan(Double(differing) / Double(max(total, 1)), 0.03,
                          "\(differing) of \(total) pixels differ")
    }

    func testARigRendersAtTheSizeAskedFor() throws {
        let document = try open(MVRTestRig.bar("Spot", count: 8, y: 0, idsFrom: 101))
        let stage = try XCTUnwrap(StageScene(document: document, geometry: nil))
        let image = stage.render(.front, size: CGSize(width: 800, height: 500))
        XCTAssertEqual(image.size.width, 800)
        XCTAssertEqual(image.size.height, 500)
    }

    /// Not a blank frame: something other than the background is drawn.
    func testTheRenderHasTheRigInIt() throws {
        let document = try open(MVRTestRig.bar("Spot", count: 8, y: 0, idsFrom: 101))
        let stage = try XCTUnwrap(StageScene(document: document, geometry: nil))
        let image = stage.render(.front, size: CGSize(width: 400, height: 250))
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))

        // The floor and the background are grey; a fixture is tinted by
        // its type. Any properly coloured pixel means the rig was drawn.
        var tinted = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.25 { tinted += 1 }
            }
        }
        XCTAssertGreaterThan(tinted, 20, "fixtures, not just floor and sky")
    }

    func testNothingPositionedMeansNothingToRender() throws {
        // Fixtures with no position at all can't make a stage.
        let url = try MVRTestRig.write(MVRTestRig.bar("Spot", count: 2, y: 0))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        for fixture in document.fixtures {
            document.setMatrix("", forFixtureAtID: fixture.id)
        }
        XCTAssertNil(StageScene(document: document, geometry: nil))
    }

    /// Page 1 is the stage, landscape; the patch list follows, portrait.
    func testThePDFLeadsWithALandscapeStagePage() throws {
        let document = try open(MVRTestRig.bar("Spot", count: 8, y: 0, idsFrom: 101))
        let stage = try XCTUnwrap(StageScene(document: document, geometry: nil))
            .render(.front, size: CGSize(width: 800, height: 500))
        let url = scratchURL("\(UUID().uuidString).pdf")

        try MVRPatchPDFExporter.export(
            fixtures: document.fixtures, layout: .byFixtureID,
            documentTitle: "Test", stageImage: stage, to: url)

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 2, "the stage, then one page of eight fixtures")
        let first = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        let second = try XCTUnwrap(pdf.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertGreaterThan(first.width, first.height, "landscape")
        XCTAssertGreaterThan(second.height, second.width, "portrait")
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Page 1 of 2") ?? false)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("for reference only") ?? false,
                      "the render says what it is")
        XCTAssertTrue(pdf.page(at: 1)?.string?.contains("Page 2 of 2") ?? false)
    }

    func testWithoutTheStageThePatchListIsPageOne() throws {
        let document = try open(MVRTestRig.bar("Spot", count: 8, y: 0, idsFrom: 101))
        let url = scratchURL("\(UUID().uuidString).pdf")

        try MVRPatchPDFExporter.export(
            fixtures: document.fixtures, layout: .byFixtureID,
            documentTitle: "Test", to: url)

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 1)
        let first = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertGreaterThan(first.height, first.width)
    }
}

/// Paper size and text size for the patch PDF.
final class PatchPDFSetupTests: XCTestCase {

    override func tearDown() {
        MVRTestRig.cleanUp()
        super.tearDown()
    }

    private func export(
        fixtures count: Int, setup: PatchPDFPageSetup, stage: NSImage? = nil
    ) throws -> PDFDocument {
        let url = try MVRTestRig.write(MVRTestRig.bar("Spot", count: count, y: 0, idsFrom: 101))
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVRExploderTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdfURL = folder.appendingPathComponent("\(UUID().uuidString).pdf")
        try MVRPatchPDFExporter.export(
            fixtures: document.fixtures, layout: .byFixtureID, documentTitle: "Test",
            stageImage: stage, setup: setup, to: pdfURL)
        return try XCTUnwrap(PDFDocument(url: pdfURL))
    }

    func testA4IsA4() throws {
        let pdf = try export(fixtures: 5, setup: PatchPDFPageSetup(paper: .a4))
        let page = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(page.width, 595)
        XCTAssertEqual(page.height, 842)
    }

    func testTheStagePageTurnsTheChosenPaper() throws {
        let image = NSImage(size: NSSize(width: 160, height: 100))
        let pdf = try export(fixtures: 5, setup: PatchPDFPageSetup(paper: .a4), stage: image)
        let first = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(first.width, 842)
        XCTAssertEqual(first.height, 595)
    }

    /// Bigger text, more pages: the rows grow with the type.
    func testLargerTextTakesMorePages() throws {
        let small = try export(fixtures: 200, setup: PatchPDFPageSetup(textSize: .small))
        let large = try export(fixtures: 200, setup: PatchPDFPageSetup(textSize: .large))
        XCTAssertGreaterThan(large.pageCount, small.pageCount)
    }

    /// Pageless is one page, A4 wide, as tall as the list.
    func testPagelessIsOnePageAsTallAsTheList() throws {
        let short = try export(fixtures: 5, setup: PatchPDFPageSetup(paper: .pageless))
        let long = try export(fixtures: 300, setup: PatchPDFPageSetup(paper: .pageless))

        XCTAssertEqual(short.pageCount, 1)
        XCTAssertEqual(long.pageCount, 1)
        let shortPage = try XCTUnwrap(short.page(at: 0)).bounds(for: .mediaBox)
        let longPage = try XCTUnwrap(long.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(longPage.width, 595)
        XCTAssertGreaterThan(longPage.height, 842 * 4, "300 fixtures run well past one A4 page")
        XCTAssertLessThan(shortPage.height, longPage.height)
        XCTAssertFalse(long.page(at: 0)?.string?.contains("Page 1 of") ?? true, "no page numbers")
        XCTAssertTrue(long.page(at: 0)?.string?.contains("101") ?? false)
        XCTAssertTrue(long.page(at: 0)?.string?.contains("400") ?? false, "the last fixture is on it")
    }

    /// Pageless with a render: still one page, the render under the title.
    func testPagelessKeepsTheRenderOnTheOnePage() throws {
        let image = NSImage(size: NSSize(width: 160, height: 100))
        let pdf = try export(fixtures: 5, setup: PatchPDFPageSetup(paper: .pageless), stage: image)
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("for reference only") ?? false)
    }

    /// Medium is what the list has always been printed at.
    func testMediumOnLetterIsTheOldLayout() throws {
        let pdf = try export(fixtures: 200, setup: PatchPDFPageSetup())
        let page = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(page.size, CGSize(width: 612, height: 792))
    }
}
