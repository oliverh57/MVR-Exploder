import XCTest
import SceneKit
@testable import MVR_Exploder

/// OBJ, FBX and DXF written from the same geometry must agree about what
/// is in it, and each must be the format it claims to be.
final class GeometryExportTests: XCTestCase {

    /// Two boxes, placed apart so the node transform has to be baked in
    /// for the extents to come out right.
    private func items() -> [MVRGeometryExport.ExportItem] {
        let deck = MVRTestRig.boxNode(
            name: "deck", width: 2, height: 1, length: 3, at: SCNVector3(5, 0, 0))
        let tower = MVRTestRig.boxNode(
            name: "tower", width: 1, height: 4, length: 1, at: SCNVector3(-5, 0, 0))
        return [
            MVRGeometryExport.ExportItem(node: deck, name: "Stage Deck"),
            MVRGeometryExport.ExportItem(node: tower, name: "Truss Tower"),
        ]
    }

    private func url(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    func testAllThreeFormatsSeeTheSameGeometry() throws {
        let obj = try MVROBJExporter.export(items: items(), to: url("obj"))
        let fbx = try MVRFBXExporter.export(items: items(), to: url("fbx"))
        let dxf = try MVRDXFExporter.export(items: items(), to: url("dxf"))

        XCTAssertEqual(obj.objectCount, 2)
        XCTAssertEqual(obj.triangleCount, 24, "two boxes of twelve triangles")
        XCTAssertEqual([fbx.objectCount, dxf.objectCount], [obj.objectCount, obj.objectCount])
        XCTAssertEqual([fbx.triangleCount, dxf.triangleCount], [obj.triangleCount, obj.triangleCount])
        XCTAssertGreaterThan(obj.triangleCount, 0)
    }

    func testEmptySelectionIsRefusedRatherThanWrittenEmpty() {
        for format in MVRGeometryExport.Format.allCases {
            XCTAssertThrowsError(
                try MVRGeometryExport.export(items: [], as: format, to: url(format.fileExtension)),
                "\(format.rawValue) should refuse an empty selection")
        }
    }

    // MARK: - OBJ

    func testOBJCarriesOneGroupPerObjectAndNoWhitespaceInNames() throws {
        let destination = url("obj")
        try MVROBJExporter.export(items: items(), to: destination)
        let lines = try String(contentsOf: destination, encoding: .utf8).split(separator: "\n")

        let groups = lines.filter { $0.hasPrefix("o ") }
        XCTAssertEqual(groups, ["o Stage_Deck", "o Truss_Tower"])
        XCTAssertTrue(lines.contains { $0.hasPrefix("v ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("f ") })
    }

    // MARK: - FBX

    /// Binary, not ASCII — Blender's importer rejects ASCII FBX outright,
    /// which is the whole reason this writes the harder format.
    func testFBXIsABinaryFBXFile() throws {
        let destination = url("fbx")
        try MVRFBXExporter.export(items: items(), to: destination)
        let data = try Data(contentsOf: destination)

        XCTAssertGreaterThan(data.count, 64)
        XCTAssertEqual(
            String(decoding: data.prefix(20), as: UTF8.self), "Kaydara FBX Binary  ",
            "must be binary FBX")
        XCTAssertEqual(Array(data[20..<23]), [0x00, 0x1A, 0x00])

        let version = data[23..<27].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: version), 7400)

        // Names are stored `name\0\1Class`, not the text form's `Class::name`.
        XCTAssertTrue(data.range(of: Data("Stage Deck\u{0}\u{1}Model".utf8)) != nil)
        XCTAssertNil(data.range(of: Data("Model::Stage Deck".utf8)))
    }

    // MARK: - DXF

    func testDXFIsR12WithOneLayerPerObject() throws {
        let destination = url("dxf")
        let summary = try MVRDXFExporter.export(items: items(), to: destination)
        let lines = try String(contentsOf: destination, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        XCTAssertTrue(lines.contains("AC1009"), "R12, the dialect everything reads")
        XCTAssertEqual(lines.last(where: { !$0.isEmpty }), "EOF")
        XCTAssertEqual(lines.filter { $0 == "3DFACE" }.count, summary.triangleCount)

        // Layer names come from the object names, spaces closed up.
        XCTAssertTrue(lines.contains("Stage_Deck"))
        XCTAssertTrue(lines.contains("Truss_Tower"))
        XCTAssertTrue(lines.contains("0"), "layer 0 is always declared")
    }

    /// CAD is Z-up; the viewer is Y-up. A rig exported without the rotation
    /// lies on its side in plan.
    func testDXFRotatesTheViewersYUpIntoCADsZUp() throws {
        let tall = MVRTestRig.boxNode(name: "tower", width: 1, height: 6, length: 1)
        let item = MVRGeometryExport.ExportItem(node: tall, name: "Tower")

        let destination = url("dxf")
        try MVRDXFExporter.export(items: [item], to: destination)
        let extent = try dxfExtent(destination)

        // 6 m tall in the viewer's Y becomes 6 m in CAD's Z.
        XCTAssertEqual(extent.z, 6, accuracy: 0.001)
        XCTAssertEqual(extent.y, 1, accuracy: 0.001)
    }

    private func dxfExtent(_ url: URL) throws -> (x: Double, y: Double, z: Double) {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var values: [String: [Double]] = [:]
        var index = 0
        while index + 1 < lines.count {
            let (code, value) = (lines[index], Double(lines[index + 1]))
            if let value, let axis = ["10", "11", "12", "13"].contains(code) ? "x"
                : ["20", "21", "22", "23"].contains(code) ? "y"
                : ["30", "31", "32", "33"].contains(code) ? "z" : nil {
                values[axis, default: []].append(value)
            }
            index += 2
        }
        func span(_ axis: String) -> Double {
            let all = values[axis] ?? [0]
            return (all.max() ?? 0) - (all.min() ?? 0)
        }
        return (span("x"), span("y"), span("z"))
    }
}
