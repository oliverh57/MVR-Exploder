import XCTest
import SceneKit
import ZIPFoundation
@testable import MVR_Exploder

/// The Geometry Inspector's list and its one-symbol render.
final class GeometryInventoryTests: XCTestCase {

    let identity = "<Matrix>{1,0,0}{0,1,0}{0,0,1}{0,0,0}</Matrix>"

    /// A clamp symbol nested twice in a truss symbol, the truss placed by
    /// three `<Truss>` objects and one scene object, plus an unused symbol
    /// and an object with a one-off mesh of its own.
    var sceneXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <GeneralSceneDescription verMajor="1" verMinor="5">
          <Scene>
            <AUXData>
              <Symdef name="Symbol Definition for Clamp" uuid="AAAAAAAA-0000-0000-0000-000000000001">
                <ChildList><Geometry3D fileName="clamp.3ds"/></ChildList>
              </Symdef>
              <Symdef name="Truss 3m" uuid="AAAAAAAA-0000-0000-0000-000000000002">
                <ChildList>
                  <Geometry3D fileName="truss.3ds"/>
                  <Symbol uuid="s1" symdef="AAAAAAAA-0000-0000-0000-000000000001">\(identity)</Symbol>
                  <Symbol uuid="s2" symdef="aaaaaaaa-0000-0000-0000-000000000001"><Matrix>{1,0,0}{0,1,0}{0,0,1}{3000,0,0}</Matrix></Symbol>
                </ChildList>
              </Symdef>
              <Symdef name="Spare" uuid="AAAAAAAA-0000-0000-0000-000000000003">
                <ChildList><Geometry3D fileName="spare.3ds"/></ChildList>
              </Symdef>
            </AUXData>
            <Layers>
              <Layer name="Rig" uuid="11111111-2222-3333-4444-555555555555">
                <ChildList>
                  \((1...3).map { index in """
                  <Truss name="T\(index)" uuid="T000000\(index)">\(identity)
                    <Geometries><Symbol uuid="t\(index)" symdef="AAAAAAAA-0000-0000-0000-000000000002"/></Geometries>
                  </Truss>
                  """ }.joined())
                  <SceneObject name="Spare truss" uuid="O0000001">\(identity)
                    <Geometries><Symbol uuid="o1" symdef="AAAAAAAA-0000-0000-0000-000000000002"/></Geometries>
                  </SceneObject>
                  <SceneObject name="Set Piece" uuid="O0000002">\(identity)
                    <Geometries><Geometry3D fileName="oneoff.3ds"/></Geometries>
                  </SceneObject>
                </ChildList>
              </Layer>
            </Layers>
          </Scene>
        </GeneralSceneDescription>
        """
    }

    func testCountsUsesThroughNesting() throws {
        let inventory = GeometryInventory.read(try XMLDocument(xmlString: sceneXML))
        let byName = Dictionary(uniqueKeysWithValues: inventory.items.map { ($0.name, $0) })

        // The Vectorworks prefix is dropped.
        let clamp = try XCTUnwrap(byName["Clamp"])
        let truss = try XCTUnwrap(byName["Truss 3m"])
        let spare = try XCTUnwrap(byName["Spare"])

        XCTAssertEqual(truss.uses, 4)
        XCTAssertEqual(truss.usage, [
            GeometryInventory.Usage(label: "trusses", count: 3),
            GeometryInventory.Usage(label: "scene object", count: 1),
        ])
        XCTAssertEqual(truss.meshCount, 1)
        XCTAssertEqual(truss.nestedSymbolCount, 2)

        // Twice per truss, whatever case the reference's uuid is in.
        XCTAssertEqual(clamp.uses, 8)
        XCTAssertEqual(clamp.usage, [GeometryInventory.Usage(label: "inside “Truss 3m”", count: 8)])

        XCTAssertEqual(spare.uses, 0)
        XCTAssertEqual(inventory.looseObjectCount, 1)
    }

    func testSelfReferencingSymbolDoesNotRecurseForever() throws {
        let xml = """
        <GeneralSceneDescription><Scene><AUXData>
          <Symdef name="Loop" uuid="L1"><ChildList><Symbol symdef="L1"/></ChildList></Symdef>
        </AUXData></Scene></GeneralSceneDescription>
        """
        let inventory = GeometryInventory.read(try XMLDocument(xmlString: xml))
        XCTAssertEqual(inventory.items.map(\.uses), [0])
    }

    func testPreviewBuildsTheSymbolWithItsNestedMeshes() async throws {
        let url = try writeMVR()
        let library = try XCTUnwrap(MVRSceneGeometryLoader.SymbolLibrary(mvrURL: url))

        let items = await library.inventory().items
        XCTAssertEqual(items.count, 3)

        // One truss mesh and two clamps, each a 1000mm triangle; the second
        // clamp 3m along X.
        let preview = await library.preview(symdef: "aaaaaaaa-0000-0000-0000-000000000002")
        let truss = try XCTUnwrap(preview)
        XCTAssertEqual(truss.meshPlacementCount, 3)
        XCTAssertEqual(truss.triangleCount, 3)
        XCTAssertEqual(truss.missingMeshCount, 0)
        XCTAssertEqual(Double(truss.boundingBox.min.x), 0, accuracy: 1e-4)
        XCTAssertEqual(Double(truss.boundingBox.max.x), 4, accuracy: 1e-4)
        // MVR Z up becomes scene Y up.
        XCTAssertEqual(Double(truss.boundingBox.max.y), 1, accuracy: 1e-4)

        // Its mesh isn't in the archive.
        let spare = await library.preview(symdef: "aaaaaaaa-0000-0000-0000-000000000003")
        XCTAssertNil(spare)
    }

    /// What the inspector's Export writes: the symbol in its own space, not
    /// the preview's re-centred one, in both formats it offers.
    func testExportedSymbolKeepsItsOwnSpace() async throws {
        let library = try XCTUnwrap(MVRSceneGeometryLoader.SymbolLibrary(mvrURL: try writeMVR()))
        let preview = await library.preview(symdef: "aaaaaaaa-0000-0000-0000-000000000002")
        let truss = try XCTUnwrap(preview)

        // Shown as the inspector shows it, centred under an offset.
        let holder = SCNNode()
        holder.position = SCNVector3(-2, -0.5, 0)
        holder.addChildNode(truss.node)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVRExploderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let item = MVRGeometryExport.ExportItem(node: truss.node.clone(), name: "Truss 3m")
        let obj = folder.appendingPathComponent("truss.obj")
        let summary = try MVRGeometryExport.export(items: [item], as: .obj, to: obj)
        XCTAssertEqual(summary.triangleCount, 3)

        let xs = try String(contentsOf: obj, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.hasPrefix("v ") }
            .compactMap { Double($0.split(separator: " ")[1]) }
        XCTAssertEqual(xs.min() ?? .nan, 0, accuracy: 1e-4)
        XCTAssertEqual(xs.max() ?? .nan, 4, accuracy: 1e-4)

        let fbx = folder.appendingPathComponent("truss.fbx")
        XCTAssertEqual(try MVRGeometryExport.export(items: [item], as: .fbx, to: fbx).triangleCount, 3)
        XCTAssertTrue(try Data(contentsOf: fbx).starts(with: Data("Kaydara FBX Binary".utf8)))
    }

    /// The 3D viewer once read `<SceneObject>` alone, so every truss,
    /// support and video screen in a file was missing from it.
    func testViewerLoadsEveryObjectTypeThatCarriesGeometry() throws {
        let objects = ["SceneObject", "Truss", "Support", "VideoScreen", "Projector", "FocusPoint"]
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <GeneralSceneDescription verMajor="1" verMinor="5"><Scene>
          <AUXData><Symdef name="Piece" uuid="P1"><ChildList><Geometry3D fileName="clamp.3ds"/></ChildList></Symdef></AUXData>
          <Layers><Layer name="Rig" uuid="11111111-2222-3333-4444-555555555555"><ChildList>
            \(objects.enumerated().map { index, tag in """
            <\(tag) name="\(tag)" uuid="U\(index)"><Matrix>{1,0,0}{0,1,0}{0,0,1}{\(index * 2000),0,0}</Matrix>
              <Geometries><Symbol uuid="S\(index)" symdef="P1"/></Geometries>
            </\(tag)>
            """ }.joined())
            <GroupObject name="Group" uuid="G1"><Matrix>{1,0,0}{0,1,0}{0,0,1}{0,0,0}</Matrix><ChildList>
              <Truss name="Grouped truss" uuid="G2"><Matrix>{1,0,0}{0,1,0}{0,0,1}{0,5000,0}</Matrix>
                <Geometries><Symbol uuid="S9" symdef="P1"/></Geometries>
              </Truss>
            </ChildList></GroupObject>
          </ChildList></Layer></Layers>
        </Scene></GeneralSceneDescription>
        """
        let url = try writeMVR(sceneXML: xml)

        let loaded = MVRSceneGeometryLoader.buildGeometryNode(mvrURL: url)
        XCTAssertEqual(loaded.objects.map(\.name), objects + ["Grouped truss"])
        XCTAssertEqual(loaded.layers.map(\.objectCount), [7])

        // Each in its own place: the truss in the group 5m upstage, which
        // is scene -Z.
        let node = try XCTUnwrap(loaded.node)
        let grouped = try XCTUnwrap(node.childNode(withName: "sceneObject:6", recursively: true))
        XCTAssertEqual(Double(grouped.worldPosition.z), -5, accuracy: 1e-4)
        let support = try XCTUnwrap(node.childNode(withName: "sceneObject:2", recursively: true))
        XCTAssertEqual(Double(support.worldPosition.x), 4, accuracy: 1e-4)
    }

    // MARK: - Fixtures

    func writeMVR(sceneXML: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVRExploderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("geometry.mvr")
        let archive = try Archive(url: url, accessMode: .create)
        try add("GeneralSceneDescription.xml", Data((sceneXML ?? self.sceneXML).utf8), to: archive)
        for name in ["clamp.3ds", "truss.3ds", "oneoff.3ds"] {
            try add(name, triangle3DS(), to: archive)
        }
        return url
    }

    func add(_ path: String, _ data: Data, to archive: Archive) throws {
        try archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count),
            provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
    }

    /// A `.3ds` holding one triangle, 1000mm along X and up Z.
    func triangle3DS() -> Data {
        func chunk(_ id: UInt16, _ body: Data) -> Data {
            var data = Data()
            withUnsafeBytes(of: id.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(body.count + 6).littleEndian) { data.append(contentsOf: $0) }
            return data + body
        }
        func little<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }

        var vertices = little(UInt16(3))
        for point: [Float] in [[0, 0, 0], [1000, 0, 0], [0, 0, 1000]] {
            for value in point { vertices += little(value.bitPattern) }
        }
        var faces = little(UInt16(1))
        for value: UInt16 in [0, 1, 2, 0] { faces += little(value) }

        let mesh = chunk(0x4100, chunk(0x4110, vertices) + chunk(0x4120, faces))
        let object = chunk(0x4000, Data("tri".utf8) + Data([0]) + mesh)
        return chunk(0x4D4D, chunk(0x3D3D, object))
    }
}
