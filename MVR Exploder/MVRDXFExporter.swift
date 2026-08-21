import Foundation
import SceneKit

/// Writes selected scene geometry out as a DXF for CAD.
///
/// **DXF, not DWG.** DWG is AutoCAD's proprietary binary format with no
/// published specification; writing it means either Autodesk's own
/// libraries or the Open Design Alliance's, both commercial and licence-
/// gated, and neither can be embedded in an app like this. DXF is
/// Autodesk's *documented* interchange format for exactly this purpose —
/// AutoCAD, Vectorworks, Rhino, SketchUp, BricsCAD and the rest open it
/// natively, and in the drawing it is the same geometry a DWG would carry.
///
/// Written as **R12 (AC1009) 3DFACE entities**: the oldest and most widely
/// understood dialect, and 3DFACE is the one mesh primitive every DXF
/// reader supports. Each exported object becomes its own layer, so pieces
/// stay separable and can be turned off individually.
///
/// **Units are metres, Z up.** CAD is Z-up — plan view is the XY plane —
/// so the viewer's Y-up coordinates are rotated back on the way out,
/// undoing exactly the transform the scene applied when it loaded them.
/// Without that a rig would lie on its side in plan.
enum MVRDXFExporter {

    typealias ExportItem = MVRGeometryExport.ExportItem
    typealias ExportSummary = MVRGeometryExport.ExportSummary

    /// DXF R12 layer names: 31 characters, and a short list of reserved
    /// punctuation the format uses for wildcards and paths.
    private static let maximumLayerNameLength = 31
    private static let forbiddenInLayerNames = CharacterSet(charactersIn: "<>/\\\":;?*|,='`")

    /// How much text to hold before pushing it at the file.
    private static let bufferFlushSize = 1 << 20

    @discardableResult
    static func export(items: [ExportItem], to url: URL) throws -> ExportSummary {
        let meshes = MVRGeometryExport.meshes(for: items)
        guard !meshes.isEmpty else { throw MVRGeometryExportError.nothingToExport }

        var usedNames: Set<String> = []
        let layerNames = meshes.map { layerName($0.name, index: $0.index, used: &usedNames) }

        // Extents first, in their own pass: they go in the header, which
        // has to be written before the entities that determine them.
        var low = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var high = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var totalTriangles = 0
        var totalVertices = 0
        for mesh in meshes {
            for part in mesh.parts {
                for position in part.positions {
                    let point = toCAD(position)
                    low = SCNVector3(min(low.x, point.x), min(low.y, point.y), min(low.z, point.z))
                    high = SCNVector3(max(high.x, point.x), max(high.y, point.y), max(high.z, point.z))
                }
                totalTriangles += part.triangles.count
                totalVertices += part.positions.count
            }
        }

        // Streamed rather than assembled in memory. A 3DFACE runs to about
        // 170 bytes, so a whole-venue selection — ten million triangles is
        // not unusual in these files — would be a 1.7 GB string held whole
        // before a byte of it reached the disk.
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw MVRGeometryExportError.cannotCreateFile(url)
        }
        defer { try? handle.close() }

        var buffer = ""
        buffer.reserveCapacity(bufferFlushSize * 2)
        func write(_ text: String) throws {
            buffer += text
            if buffer.utf8.count >= bufferFlushSize {
                try handle.write(contentsOf: Data(buffer.utf8))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        try write(header(low: low, high: high))
        try write(tables(layerNames: layerNames))
        try write("0\nSECTION\n2\nENTITIES\n")

        for (mesh, layer) in zip(meshes, layerNames) {
            for part in mesh.parts {
                // Drained per part, and it matters more than it looks:
                // every coordinate goes through `String(format:)`, which
                // allocates an autoreleased NSString. At twelve per
                // triangle and ten million triangles that is a hundred
                // million objects with nothing to release them — measured
                // at 6.2 GB above the cost of the geometry itself, on one
                // real file, before this pool was added.
                try autoreleasepool {
                    let points = part.positions.map(toCAD)
                    for triangle in part.triangles {
                        try write(face(
                            points[triangle.a], points[triangle.b], points[triangle.c],
                            layer: layer))
                    }
                }
            }
        }

        try write("0\nENDSEC\n0\nEOF\n")
        try handle.write(contentsOf: Data(buffer.utf8))

        return ExportSummary(
            objectCount: meshes.count, triangleCount: totalTriangles, vertexCount: totalVertices)
    }

    // MARK: - Coordinates

    /// Viewer space (X right, Y up, Z toward the viewer, metres) → CAD
    /// space (X right, Y depth, Z up, metres).
    ///
    /// The exact inverse of the rotation `MVRSceneGeometryLoader` applies
    /// when it reads the MVR, so what comes out is oriented as the MVR had
    /// it — which is the orientation a CAD drawing of the rig wants.
    private nonisolated static func toCAD(_ v: SCNVector3) -> SCNVector3 {
        SCNVector3(v.x, -v.z, v.y)
    }

    // MARK: - Sections

    private static func header(low: SCNVector3, high: SCNVector3) -> String {
        // A degenerate selection would otherwise write ±FLT_MAX and put
        // the drawing extents somewhere no CAD app can zoom to.
        let hasExtent = low.x <= high.x
        let lo = hasExtent ? low : SCNVector3(0, 0, 0)
        let hi = hasExtent ? high : SCNVector3(0, 0, 0)

        return """
        999
        Exported from MVR Exploder — units: metres, Z up
        0
        SECTION
        2
        HEADER
        9
        $ACADVER
        1
        AC1009
        9
        $INSUNITS
        70
        6
        9
        $EXTMIN
        10
        \(number(lo.x))
        20
        \(number(lo.y))
        30
        \(number(lo.z))
        9
        $EXTMAX
        10
        \(number(hi.x))
        20
        \(number(hi.y))
        30
        \(number(hi.z))
        0
        ENDSEC

        """
    }

    private static func tables(layerNames: [String]) -> String {
        // Layer 0 always exists in a DXF and is what an entity falls back
        // to, so it is declared alongside the ones we invent.
        var block = "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n\(layerNames.count + 1)\n"
        block += layerRecord("0")
        for name in layerNames { block += layerRecord(name) }
        block += "0\nENDTAB\n0\nENDSEC\n"
        return block
    }

    /// 70 = flags (0, nothing frozen or locked), 62 = colour (7, the
    /// drawing's default foreground), 6 = line type.
    private static func layerRecord(_ name: String) -> String {
        "0\nLAYER\n2\n\(name)\n70\n0\n62\n7\n6\nCONTINUOUS\n"
    }

    /// A 3DFACE is a quad; a triangle is written by repeating the third
    /// corner as the fourth, which is the format's own convention.
    private static func face(
        _ a: SCNVector3, _ b: SCNVector3, _ c: SCNVector3, layer: String
    ) -> String {
        var entity = "0\n3DFACE\n8\n\(layer)\n"
        for (index, point) in [a, b, c, c].enumerated() {
            entity += "\(10 + index)\n\(number(point.x))\n"
            entity += "\(20 + index)\n\(number(point.y))\n"
            entity += "\(30 + index)\n\(number(point.z))\n"
        }
        return entity
    }

    // MARK: - Formatting

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.6f", Double(value))
    }

    private static func layerName(_ name: String, index: Int, used: inout Set<String>) -> String {
        var cleaned = name
            .components(separatedBy: forbiddenInLayerNames)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        if cleaned.isEmpty { cleaned = "object_\(index)" }
        if cleaned.count > maximumLayerNameLength {
            cleaned = String(cleaned.prefix(maximumLayerNameLength))
        }

        // Two objects on one layer would merge in the drawing, and the
        // point of a layer per object is that they don't.
        var candidate = cleaned
        var suffix = 2
        while used.contains(candidate.uppercased()) {
            let tail = "_\(suffix)"
            candidate = String(cleaned.prefix(maximumLayerNameLength - tail.count)) + tail
            suffix += 1
        }
        used.insert(candidate.uppercased())
        return candidate
    }
}
