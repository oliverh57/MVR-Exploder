import Foundation
import SceneKit
import ZIPFoundation
@testable import MVR_Exploder

/// Builds small MVR files from scratch, so tests describe the rig they are
/// about instead of depending on a show file.
///
/// Real files were the obvious alternative and are the wrong call twice
/// over: they are client show files that have no business in a repository,
/// and a test that asserts "this truss numbers 1001–1010" is unreadable
/// unless the reader can see where the fixtures are. Here the rig is in the
/// test. `MVRCorpus` covers real files separately, off a path the user
/// supplies.
enum MVRTestRig {

    /// One fixture, positioned in MVR space: X stage-right to stage-left,
    /// Y upstage, Z up — in **millimetres**, as the format stores them.
    struct Fixture {
        var name: String
        var type: String
        var id: Int?
        var x: Double
        var y: Double
        var z: Double
        var uuid: String

        init(name: String, type: String, id: Int? = nil,
             x: Double, y: Double, z: Double, uuid: String = UUID().uuidString) {
            self.name = name
            self.type = type
            self.id = id
            self.x = x
            self.y = y
            self.z = z
            self.uuid = uuid
        }
    }

    /// A straight bar of `count` fixtures, evenly spaced across the centre
    /// line at depth `y` and height `z` — the shape most of these tests are
    /// about.
    static func bar(
        _ type: String, count: Int, y: Double, z: Double = 8000,
        spacing: Double = 1500, centre: Double = 0, idsFrom: Int? = nil
    ) -> [Fixture] {
        let span = Double(count - 1) * spacing
        return (0..<count).map { index in
            Fixture(
                name: "\(type) \(index + 1)",
                type: type,
                id: idsFrom.map { $0 + index },
                x: centre - span / 2 + Double(index) * spacing,
                y: y,
                z: z)
        }
    }

    /// Writes an MVR to a temporary file and returns its URL. Deleted by
    /// `cleanUp`, which the test case calls in `tearDown`.
    static func write(
        _ fixtures: [Fixture],
        layer: String = "Lighting",
        sceneObjects: [SceneObject] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> URL {
        let url = temporaryDirectory().appendingPathComponent("\(UUID().uuidString).mvr")
        let xml = sceneDescription(fixtures: fixtures, layer: layer, sceneObjects: sceneObjects)

        let workDir = temporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let xmlURL = workDir.appendingPathComponent("GeneralSceneDescription.xml")
        try Data(xml.utf8).write(to: xmlURL)

        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "GeneralSceneDescription.xml", fileURL: xmlURL)
        return url
    }

    /// A `<SceneObject>`, which MVR uses both for venue geometry and — the
    /// case that once cost every fixture in a file on export — as a
    /// container with fixtures nested inside it.
    struct SceneObject {
        var name: String
        var uuid = UUID().uuidString
        /// Fixtures living inside this object's own `<ChildList>`.
        var fixtures: [Fixture] = []
    }

    // MARK: - XML

    private static func sceneDescription(
        fixtures: [Fixture], layer: String, sceneObjects: [SceneObject]
    ) -> String {
        let layerUUID = "11111111-2222-3333-4444-555555555555"
        var children = fixtures.map(fixtureXML).joined(separator: "\n")
        for object in sceneObjects {
            children += "\n" + sceneObjectXML(object)
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <GeneralSceneDescription verMajor="1" verMinor="5">
          <Scene>
            <Layers>
              <Layer name="\(escaped(layer))" uuid="\(layerUUID)">
                <ChildList>
        \(children)
                </ChildList>
              </Layer>
            </Layers>
          </Scene>
        </GeneralSceneDescription>
        """
    }

    private static func sceneObjectXML(_ object: SceneObject) -> String {
        let nested = object.fixtures.map(fixtureXML).joined(separator: "\n")
        return """
                  <SceneObject name="\(escaped(object.name))" uuid="\(object.uuid)">
                    <Matrix>{1.000000,0.000000,0.000000}{0.000000,1.000000,0.000000}{0.000000,0.000000,1.000000}{0.000000,0.000000,0.000000}</Matrix>
                    <Geometries/>
                    <ChildList>
        \(nested)
                    </ChildList>
                  </SceneObject>
        """
    }

    private static func fixtureXML(_ fixture: Fixture) -> String {
        let id = fixture.id.map { "\n            <FixtureID>\($0)</FixtureID>" } ?? ""
        return """
                  <Fixture name="\(escaped(fixture.name))" uuid="\(fixture.uuid)">
                    <GDTFSpec>\(escaped(fixture.type)).gdtf</GDTFSpec>
                    <GDTFMode>Standard</GDTFMode>
                    <Matrix>{1.000000,0.000000,0.000000}{0.000000,1.000000,0.000000}{0.000000,0.000000,1.000000}{\(fixture.x),\(fixture.y),\(fixture.z)}</Matrix>\(id)
                    <Addresses><Address break="0">1</Address></Addresses>
                  </Fixture>
        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Geometry

    /// A box built from explicit vertices, as one `SCNNode`.
    ///
    /// Deliberately not `SCNBox`. SceneKit's parametric primitives keep
    /// their dimensions *outside* the vertex data — an `SCNBox` of any size
    /// reads back as a unit cube from `sources(for: .vertex)` — so they
    /// make useless doubles for an exporter that reads raw sources. What
    /// the app actually exports is scene geometry the MVR loader builds
    /// from parsed vertex arrays, which is what this is.
    static func boxNode(
        name: String, width: Double, height: Double, length: Double,
        at centre: SCNVector3 = SCNVector3(0, 0, 0)
    ) -> SCNNode {
        let (x, y, z) = (width / 2, height / 2, length / 2)
        let corners: [SCNVector3] = [
            SCNVector3(-x, -y, -z), SCNVector3(x, -y, -z), SCNVector3(x, y, -z), SCNVector3(-x, y, -z),
            SCNVector3(-x, -y, z), SCNVector3(x, -y, z), SCNVector3(x, y, z), SCNVector3(-x, y, z),
        ]
        let faces: [(Int, Int, Int)] = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (2, 3, 7), (2, 7, 6),
            (1, 2, 6), (1, 6, 5), (0, 4, 7), (0, 7, 3),
        ]

        let source = SCNGeometrySource(vertices: corners)
        let indices = faces.flatMap { [Int32($0.0), Int32($0.1), Int32($0.2)] }
        let element = SCNGeometryElement(
            data: Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size),
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: MemoryLayout<Int32>.size)

        let node = SCNNode(geometry: SCNGeometry(sources: [source], elements: [element]))
        node.name = name
        node.position = centre
        return node
    }

    // MARK: - Scratch space

    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MVRExploderTests", isDirectory: true)

    private static func temporaryDirectory() -> URL {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
