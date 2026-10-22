import XCTest
import SceneKit
import ZIPFoundation
@testable import MVR_Exploder

/// Deleting and simplifying geometry in the Geometry Inspector, and the
/// mesh reading and writing underneath.
extension GeometryInventoryTests {

    private func open(_ url: URL) throws -> (MVRDocument, UndoManager) {
        let document = MVRDocument()
        try document.load(from: url, idFieldName: "FixtureID")
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (document, undo)
    }

    private func edit(_ undo: UndoManager, _ change: () -> Void) {
        undo.beginUndoGrouping()
        change()
        undo.endUndoGrouping()
    }

    private func inventory(_ document: MVRDocument) async throws -> GeometryInventory {
        let source = try XCTUnwrap(document.geometrySource)
        let library = try XCTUnwrap(MVRSceneGeometryLoader.SymbolLibrary(source: source))
        return await library.inventory()
    }

    private func entries(_ url: URL) throws -> Set<String> {
        Set(try Archive(url: url, accessMode: .read).map(\.path))
    }

    private func exportURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVRExploderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("out.mvr")
    }

    private var exportOptions: MVRExportOptions {
        MVRExportOptions(
            includeSceneGeometry: true, assignLayersByFixtureType: false,
            replaceAllWithDummyGDTFs: false, cleanupEmptyClassesAndLayers: false)
    }

    // MARK: - Delete

    /// Deleting the truss symbol takes its placements and the objects
    /// they leave empty with it, and its mesh drops out of the export. The
    /// clamp it nested stays: another symbol's mesh, now just unused.
    func testDeletingASymbolTakesItsPlacementsAndEmptiedObjects() async throws {
        let (document, undo) = try open(try writeMVR())
        edit(undo) { document.deleteSymbols(["AAAAAAAA-0000-0000-0000-000000000002"]) }

        let after = try await inventory(document)
        XCTAssertEqual(after.items.map(\.name).sorted(), ["Clamp", "Spare"])
        XCTAssertEqual(after.items.first { $0.name == "Clamp" }?.uses, 0)
        XCTAssertEqual(after.objects.map(\.name), ["Set Piece"])
        XCTAssertEqual(document.droppedMeshFiles, ["truss.3ds"])
        XCTAssertGreaterThan(document.editCount, 0)

        let url = try exportURL()
        try MVRExporter.export(document, to: url, options: exportOptions)
        let written = try entries(url)
        XCTAssertFalse(written.contains("truss.3ds"))
        XCTAssertTrue(written.contains("clamp.3ds"))

        undo.undo()
        let restored = try await inventory(document)
        XCTAssertEqual(restored.items.first { $0.name == "Truss 3m" }?.uses, 4)
        XCTAssertEqual(restored.objects.count, 5)
        XCTAssertEqual(document.droppedMeshFiles, [])

        undo.redo()
        let redone = try await inventory(document)
        XCTAssertEqual(redone.objects.count, 1)
    }

    /// A scene object holding fixtures is a container as much as geometry:
    /// deleting it keeps the fixtures and takes only its own meshes.
    func testDeletingAnObjectThatHoldsFixturesKeepsThem() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <GeneralSceneDescription verMajor="1" verMinor="5"><Scene><Layers>
          <Layer name="Rig" uuid="11111111-2222-3333-4444-555555555555"><ChildList>
            <SceneObject name="Pod" uuid="P1">\(identity)
              <Geometries><Geometry3D fileName="oneoff.3ds"/></Geometries>
              <ChildList>
                <Fixture name="Spot 1" uuid="F1">\(identity)<GDTFSpec>Spot.gdtf</GDTFSpec><GDTFMode>Std</GDTFMode><FixtureID>1</FixtureID></Fixture>
              </ChildList>
            </SceneObject>
            <Truss name="Bar" uuid="T1">\(identity)<Geometries><Geometry3D fileName="truss.3ds"/></Geometries></Truss>
          </ChildList></Layer>
        </Layers></Scene></GeneralSceneDescription>
        """
        let (document, undo) = try open(try writeMVR(sceneXML: xml))
        edit(undo) { document.deleteGeometryObjects(["p1", "t1"]) }

        XCTAssertEqual(document.fixtures.map(\.name), ["Spot 1"])
        let after = try await inventory(document)
        XCTAssertEqual(after.objects.map(\.name), ["Pod"])
        XCTAssertEqual(after.objects.first?.modelSummary, "—")
        XCTAssertEqual(document.droppedMeshFiles, ["oneoff.3ds", "truss.3ds"])

        // The fixture survives export inside its container.
        let url = try exportURL()
        try MVRExporter.export(document, to: url, options: exportOptions)
        let file = try MVRDocument.read(from: url)
        XCTAssertEqual(try file.xml.nodes(forXPath: "//SceneObject/ChildList/Fixture").count, 1)
    }

    // MARK: - Object settings

    /// Two layers, a truss 2m stage-left in the first.
    private var twoLayerXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <GeneralSceneDescription verMajor="1" verMinor="5"><Scene><Layers>
          <Layer name="Rig" uuid="11111111-2222-3333-4444-555555555555"><ChildList>
            <Truss name="Bar" uuid="T1"><Matrix>{0,1,0}{-1,0,0}{0,0,1}{2000,0,0}</Matrix>
              <Geometries><Geometry3D fileName="truss.3ds"/></Geometries></Truss>
            <SceneObject name="Riser" uuid="R1"><Geometries><Geometry3D fileName="oneoff.3ds"/></Geometries></SceneObject>
          </ChildList></Layer>
          <Layer name="Set" uuid="AAAAAAAA-2222-3333-4444-555555555555"><ChildList/></Layer>
        </Layers></Scene></GeneralSceneDescription>
        """
    }

    func testRenamingMovingAndRelayeringObjectsUndo() async throws {
        let (document, undo) = try open(try writeMVR(sceneXML: twoLayerXML))
        let sceneBefore = document.sceneRevision

        edit(undo) { document.renameGeometryObject("t1", to: "LX1") }
        edit(undo) { document.moveGeometryObjects(["t1", "r1"], toLayer: "aaaaaaaa-2222-3333-4444-555555555555") }
        // A rename and a change of layer don't change how the scene looks.
        XCTAssertEqual(document.sceneRevision, sceneBefore)
        edit(undo) { document.setGeometryObjectPosition("r1", to: SIMD3(0, 5000, 300)) }
        edit(undo) { document.setGeometryObjectPosition("t1", to: SIMD3(-1000, 0, 8000)) }
        XCTAssertEqual(document.sceneRevision, sceneBefore + 2)

        var objects = try await inventory(document).objects
        XCTAssertEqual(objects.map(\.name), ["LX1", "Riser"])
        XCTAssertEqual(objects.map(\.layer), ["Set", "Set"])
        XCTAssertEqual(objects.map(\.id), ["t1", "r1"])
        XCTAssertEqual(objects[0].position, SIMD3(-1000, 0, 8000))
        // A matrix was made for the one that had none.
        XCTAssertEqual(objects[1].position, SIMD3(0, 5000, 300))
        // The truss kept its rotation.
        let matrix = try XCTUnwrap(document.xmlDocument?.nodes(forXPath: "//Truss/Matrix").first?.stringValue)
        XCTAssertTrue(matrix.hasPrefix("{0.000000,1.000000,0.000000}{-1.000000,0.000000,0.000000}"), matrix)

        for _ in 0..<4 { undo.undo() }
        objects = try await inventory(document).objects
        XCTAssertEqual(objects.map(\.name), ["Bar", "Riser"])
        XCTAssertEqual(objects.map(\.layer), ["Rig", "Rig"])
        XCTAssertEqual(objects[0].position, SIMD3(2000, 0, 0))
        XCTAssertNil(objects[1].position)

        undo.redo()
        undo.redo()
        objects = try await inventory(document).objects
        XCTAssertEqual(objects.map(\.layer), ["Set", "Set"])
    }

    /// The fixtures inside a container would move with it, behind the
    /// fixture list's back, so it stays put.
    func testAnObjectHoldingFixturesStaysInItsLayer() async throws {
        let xml = twoLayerXML.replacingOccurrences(
            of: "<Geometries><Geometry3D fileName=\"oneoff.3ds\"/></Geometries></SceneObject>",
            with: "<Geometries><Geometry3D fileName=\"oneoff.3ds\"/></Geometries><ChildList><Fixture name=\"Spot\" uuid=\"F1\"><FixtureID>1</FixtureID></Fixture></ChildList></SceneObject>")
        let (document, undo) = try open(try writeMVR(sceneXML: xml))
        edit(undo) { document.moveGeometryObjects(["r1"], toLayer: "aaaaaaaa-2222-3333-4444-555555555555") }
        let objects = try await inventory(document).objects
        XCTAssertEqual(objects.first { $0.id == "r1" }?.layer, "Rig")
        XCTAssertEqual(objects.first { $0.id == "r1" }?.holdsFixtures, true)
        XCTAssertEqual(document.editCount, 0)
    }

    /// Objects go by uuid, and by place in the file only where a uuid is
    /// missing or shared.
    func testObjectKeysFallBackToPositionWithoutAUniqueUUID() throws {
        let xml = try XMLDocument(xmlString: """
        <Scene><SceneObject uuid="A1"/><Truss/><Truss uuid="dup"/><Support uuid="DUP"/><VideoScreen uuid="B2"/></Scene>
        """)
        let elements = try xml.nodes(forXPath: MVRSceneGeometryLoader.geometryObjectsXPath).compactMap { $0 as? XMLElement }
        XCTAssertEqual(MVRSceneGeometryLoader.objectKeys(elements), ["a1", "#1", "#2", "#3", "b2"])
    }

    /// The highlight sits where the object stands in the scene — the
    /// truss's own matrix applied, rotation and all — matching the box the
    /// whole-scene view draws it in.
    func testHighlightIsBuiltWhereTheObjectStands() async throws {
        let (document, _) = try open(try writeMVR(sceneXML: twoLayerXML))
        let library = try XCTUnwrap(MVRSceneGeometryLoader.SymbolLibrary(source: try XCTUnwrap(document.geometrySource)))
        let built = await library.highlight(objects: ["t1"])
        let highlight = try XCTUnwrap(built)
        let scene = MVRSceneGeometryLoader.buildGeometryNode(source: try XCTUnwrap(document.geometrySource))
        let node = try XCTUnwrap(scene.node?.childNode(withName: "sceneObject:0", recursively: true))
        XCTAssertEqual(scene.objects.first?.key, "t1")

        // Same box as the scene draws it.
        let (low, high) = node.boundingBox
        let world = [low, high].map { node.convertPosition($0, to: nil) }
        let lowWorld = SCNVector3(min(world[0].x, world[1].x), min(world[0].y, world[1].y), min(world[0].z, world[1].z))
        let highWorld = SCNVector3(max(world[0].x, world[1].x), max(world[0].y, world[1].y), max(world[0].z, world[1].z))
        for (a, b) in [(highlight.boundingBox.min, lowWorld), (highlight.boundingBox.max, highWorld)] {
            XCTAssertEqual(Double(a.x), Double(b.x), accuracy: 1e-4)
            XCTAssertEqual(Double(a.y), Double(b.y), accuracy: 1e-4)
            XCTAssertEqual(Double(a.z), Double(b.z), accuracy: 1e-4)
        }
        XCTAssertEqual(Double(highlight.boundingBox.min.x), 2, accuracy: 1e-4)
    }

    // MARK: - Select All with Same…

    /// A one-triangle `.3ds` carrying one material of the given colour,
    /// as bytes or as floats — exporters write either.
    private func coloured3DS(_ rgb: (UInt8, UInt8, UInt8), asFloats: Bool = false, shiftedBy shift: Float = 0) -> Data {
        func chunk(_ id: UInt16, _ body: Data) -> Data { little(id) + little(UInt32(body.count + 6)) + body }
        func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let colour = asFloats
            ? chunk(0x0010, [rgb.0, rgb.1, rgb.2].reduce(Data()) { $0 + little((Float($1) / 255).bitPattern) })
            : chunk(0x0011, Data([rgb.0, rgb.1, rgb.2]))
        let material = chunk(0xAFFF, chunk(0xA000, Data("Material_0".utf8) + Data([0])) + chunk(0xA020, colour))
        var vertices = little(UInt16(3))
        for point: [Float] in [[shift, 0, 0], [1000, 0, 0], [0, 0, 1000]] {
            for value in point { vertices += little(value.bitPattern) }
        }
        var faces = little(UInt16(1))
        for value: UInt16 in [0, 1, 2, 0] { faces += little(value) }
        let mesh = chunk(0x4000, Data("tri".utf8) + Data([0]) + chunk(0x4100, chunk(0x4110, vertices) + chunk(0x4120, faces)))
        return chunk(0x4D4D, chunk(0x3D3D, material + mesh))
    }

    func testMaterialColoursAreReadFromBothFormats() throws {
        XCTAssertEqual(MeshFile.materialColours(coloured3DS((51, 102, 255)), fileName: "a.3ds"), [0x3366FF])
        XCTAssertEqual(MeshFile.materialColours(coloured3DS((255, 0, 0), asFloats: true), fileName: "a.3ds"), [0xFF0000])
        XCTAssertEqual(MeshFile.materialColours(triangle3DS(), fileName: "a.3ds"), [])

        let json = #"{"asset":{"version":"2.0"},"materials":[{"pbrMetallicRoughness":{"baseColorFactor":[0,1,0.5,1]}}]}"#
        var padded = Data(json.utf8)
        while padded.count % 4 != 0 { padded.append(0x20) }
        func little(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let glb = little(0x46546C67) + little(2) + little(UInt32(20 + padded.count)) + little(UInt32(padded.count)) + little(0x4E4F534A) + padded
        XCTAssertEqual(MeshFile.materialColours(glb, fileName: "a.glb"), [0x00FF80])
    }

    /// Objects match on model when they place the same symbol or carry
    /// meshes with identical contents under different file names.
    func testObjectsMatchOnModelAndMaterial() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <GeneralSceneDescription verMajor="1" verMinor="5"><Scene>
          <AUXData><Symdef name="Clamp" uuid="C1"><ChildList><Geometry3D fileName="clamp.3ds"/></ChildList></Symdef></AUXData>
          <Layers><Layer name="Set" uuid="11111111-2222-3333-4444-555555555555"><ChildList>
            <SceneObject name="Blue 1" uuid="A"><Geometries><Geometry3D fileName="blue1.3ds"/></Geometries></SceneObject>
            <SceneObject name="Blue 2" uuid="B"><Geometries><Geometry3D fileName="blue2.3ds"/></Geometries></SceneObject>
            <SceneObject name="Blue other" uuid="C"><Geometries><Geometry3D fileName="blue3.3ds"/></Geometries></SceneObject>
            <SceneObject name="Red" uuid="D"><Geometries><Geometry3D fileName="red.3ds"/></Geometries></SceneObject>
            <Truss name="T1" uuid="E"><Geometries><Symbol symdef="C1"/></Geometries></Truss>
            <Truss name="T2" uuid="F"><Geometries><Symbol symdef="c1"/></Geometries></Truss>
            <SceneObject name="Empty" uuid="G"/>
          </ChildList></Layer></Layers>
        </Scene></GeneralSceneDescription>
        """
        let url = try writeMVR(sceneXML: xml)
        do {
            let archive = try Archive(url: url, accessMode: .update)
            try add("blue1.3ds", coloured3DS((0, 0, 255)), to: archive)
            try add("blue2.3ds", coloured3DS((0, 0, 255)), to: archive)
            try add("blue3.3ds", coloured3DS((0, 0, 255), shiftedBy: 5), to: archive)
            try add("red.3ds", coloured3DS((255, 0, 0)), to: archive)
        }
        let library = try XCTUnwrap(MVRSceneGeometryLoader.SymbolLibrary(mvrURL: url))
        let traits = await library.traits()

        XCTAssertEqual(traits["a"]?.model, traits["b"]?.model)
        XCTAssertNotEqual(traits["a"]?.model, traits["c"]?.model)
        XCTAssertNotEqual(traits["a"]?.model, traits["d"]?.model)
        XCTAssertEqual(traits["e"]?.model, traits["f"]?.model)
        XCTAssertNil(traits["g"]?.model)

        XCTAssertEqual(traits["c"]?.colours, [0x0000FF])
        XCTAssertEqual(traits["d"]?.colours, [0xFF0000])
        // The clamp symbol's mesh has no material.
        XCTAssertEqual(traits["e"]?.colours, [])
    }

    // MARK: - Simplify

    /// A simplified mesh replaces the file's copy everywhere: the library,
    /// the 3D viewer's loader and the export — and undo puts it back.
    func testSimplifiedMeshesReplaceTheOriginalsEverywhere() async throws {
        let sphere = Self.sphere3DS()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <GeneralSceneDescription verMajor="1" verMinor="5"><Scene>
          <AUXData><Symdef name="Ball" uuid="B1"><ChildList><Geometry3D fileName="ball.3ds"/></ChildList></Symdef></AUXData>
          <Layers><Layer name="Set" uuid="11111111-2222-3333-4444-555555555555"><ChildList>
            <SceneObject name="Ball" uuid="O1">\(identity)<Geometries><Symbol uuid="S1" symdef="B1"/></Geometries></SceneObject>
          </ChildList></Layer></Layers>
        </Scene></GeneralSceneDescription>
        """
        let source = try writeMVR(sceneXML: xml)
        let withBall = try exportURL()
        do {
            let archive = try Archive(url: source, accessMode: .update)
            try add("ball.3ds", sphere, to: archive)
        }
        try FileManager.default.copyItem(at: source, to: withBall)

        let (document, undo) = try open(withBall)
        let library = try XCTUnwrap(MVRSceneGeometryLoader.SymbolLibrary(source: try XCTUnwrap(document.geometrySource)))
        let keys = await library.meshKeys(symdefs: ["b1"])
        XCTAssertEqual(keys, ["ball.3ds"])
        let before = await library.triangleCount(meshKeys: keys)
        let result = await library.simplify(meshKeys: keys, keeping: 0.25)
        XCTAssertEqual(result.trianglesBefore, before)
        XCTAssertLessThan(result.trianglesAfter, before / 3)
        edit(undo) { document.replaceMeshFiles(result.files) }

        func viewerTriangles() throws -> Int {
            let loaded = MVRSceneGeometryLoader.buildGeometryNode(source: try XCTUnwrap(document.geometrySource))
            var count = 0
            loaded.node?.enumerateHierarchy { node, _ in
                count += (node.geometry?.elements ?? []).reduce(0) { $0 + $1.primitiveCount }
            }
            return count
        }
        XCTAssertEqual(try viewerTriangles(), result.trianglesAfter)

        let url = try exportURL()
        try MVRExporter.export(document, to: url, options: exportOptions)
        let reread = try XCTUnwrap(MVRSceneGeometryLoader.SymbolLibrary(mvrURL: url))
        let exported = await reread.preview(symdef: "b1")
        XCTAssertEqual(exported?.triangleCount, result.trianglesAfter)

        undo.undo()
        XCTAssertEqual(try viewerTriangles(), before)
    }

    /// Coarser but the same shape: every face still points out of the
    /// sphere, and every vertex is still on it.
    func testSimplifyingKeepsTheShape() throws {
        let original = try XCTUnwrap(MeshFile.read(Self.sphere3DS(), fileName: "ball.3ds"))
        let simple = MeshSimplifier.simplify(original, keeping: 0.3)

        XCTAssertLessThanOrEqual(simple.triangleCount, Int(Double(original.triangleCount) * 0.31))
        XCTAssertGreaterThan(simple.triangleCount, 50)
        for point in simple.positions {
            XCTAssertEqual(simd_length(point), 1000, accuracy: 60)
        }
        for corner in stride(from: 0, to: simple.indices.count, by: 3) {
            let a = simple.positions[simple.indices[corner]]
            let b = simple.positions[simple.indices[corner + 1]]
            let c = simple.positions[simple.indices[corner + 2]]
            XCTAssertGreaterThan(simd_dot(simd_cross(b - a, c - a), a + b + c), 0)
        }
    }

    func testTinyMeshesAreLeftAlone() throws {
        let triangle = try XCTUnwrap(MeshFile.read(triangle3DS(), fileName: "t.3ds"))
        XCTAssertEqual(MeshSimplifier.simplify(triangle, keeping: 0.1).triangleCount, 1)
    }

    // MARK: - Mesh files

    /// Past 65,535 vertices a `.3ds` has to be split into objects, and the
    /// reader has to offset each object's faces onto its own vertices.
    func testLargeMeshesRoundTripThroughBothFormats() throws {
        let side = 300
        var positions: [SIMD3<Double>] = []
        var indices: [Int] = []
        for row in 0...side {
            for column in 0...side { positions.append(SIMD3(Double(column), Double(row), Double((row * column) % 7))) }
        }
        for row in 0..<side {
            for column in 0..<side {
                let a = row * (side + 1) + column, b = a + 1, c = a + side + 1, d = c + 1
                indices += [a, b, d, a, d, c]
            }
        }
        let grid = MeshSimplifier.Mesh(positions: positions, indices: indices)
        XCTAssertGreaterThan(grid.positions.count, 65_535)

        for name in ["grid.3ds", "grid.glb"] {
            let data = try XCTUnwrap(MeshFile.write(grid, fileName: name))
            let back = try XCTUnwrap(MeshFile.read(data, fileName: name))
            XCTAssertEqual(back.triangleCount, grid.triangleCount, name)
            // Same triangles, corner for corner.
            for corner in stride(from: 0, to: grid.indices.count, by: 997) {
                XCTAssertEqual(back.positions[back.indices[corner]], grid.positions[grid.indices[corner]], name)
            }
        }
    }

    /// A `.3ds` sphere of radius 1000mm, every face with its own three
    /// vertices as scene meshes have them, wound outwards.
    static func sphere3DS() -> Data {
        var positions: [SIMD3<Double>] = []
        var indices: [Int] = []
        let rings = 24, segments = 48
        func point(_ ring: Int, _ segment: Int) -> SIMD3<Double> {
            let theta = Double(ring) / Double(rings) * .pi
            let phi = Double(segment) / Double(segments) * 2 * .pi
            return SIMD3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)) * 1000
        }
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = point(ring, segment), b = point(ring + 1, segment)
                let c = point(ring + 1, segment + 1), d = point(ring, segment + 1)
                for triangle in [[a, b, c], [a, c, d]] {
                    let normal = simd_cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
                    guard simd_length(normal) > 1e-9 else { continue }
                    let outward = simd_dot(normal, triangle[0] + triangle[1] + triangle[2]) > 0
                    for vertex in outward ? triangle : triangle.reversed() {
                        indices.append(positions.count)
                        positions.append(vertex)
                    }
                }
            }
        }
        return MeshFile.write(MeshSimplifier.Mesh(positions: positions, indices: indices), fileName: "ball.3ds")!
    }
}
