import Foundation
import SceneKit

/// Kept as its own name for the call sites that already use it.
typealias MVROBJExportError = MVRGeometryExportError

/// Writes selected scene geometry out as a Wavefront OBJ.
///
/// The plain-text lingua franca of 3D: everything reads it, and it carries
/// what matters here — triangles, normals, and per-object grouping so
/// pieces stay separable in Blender, Cinema 4D and friends. FBX is the
/// richer option and DXF the one for CAD; see those exporters.
///
/// Written in the viewer's own space: **metres, Y up**.
enum MVROBJExporter {

    typealias ExportItem = MVRGeometryExport.ExportItem
    typealias ExportSummary = MVRGeometryExport.ExportSummary

    @discardableResult
    static func export(items: [ExportItem], to url: URL) throws -> ExportSummary {
        let meshes = MVRGeometryExport.meshes(for: items)
        guard !meshes.isEmpty else { throw MVRGeometryExportError.nothingToExport }

        var output = ""
        output.reserveCapacity(1 << 20)
        output += "# Exported from MVR Exploder\n"
        output += "# Units: metres, Y up\n"

        // OBJ indices are 1-based and run across the whole file, so they
        // accumulate rather than resetting per object.
        var vertexBase = 1
        var normalBase = 1
        var totalTriangles = 0
        var totalVertices = 0

        for mesh in meshes {
            output += "o \(sanitized(mesh.name, fallbackIndex: mesh.index))\n"

            var objectVertices = 0
            var objectNormals = 0

            // Every coordinate goes through `String(format:)`, which leaves
            // an autoreleased NSString behind; without a pool they pile up
            // for the whole export. See the note in the DXF exporter.
            for part in mesh.parts { autoreleasepool {
                for position in part.positions {
                    output += "v \(fmt(position.x)) \(fmt(position.y)) \(fmt(position.z))\n"
                }
                for normal in part.normals {
                    output += "vn \(fmt(normal.x)) \(fmt(normal.y)) \(fmt(normal.z))\n"
                }

                let hasNormals = !part.normals.isEmpty
                for triangle in part.triangles {
                    let va = vertexBase + objectVertices + triangle.a
                    let vb = vertexBase + objectVertices + triangle.b
                    let vc = vertexBase + objectVertices + triangle.c
                    if hasNormals {
                        let na = normalBase + objectNormals + triangle.a
                        let nb = normalBase + objectNormals + triangle.b
                        let nc = normalBase + objectNormals + triangle.c
                        output += "f \(va)//\(na) \(vb)//\(nb) \(vc)//\(nc)\n"
                    } else {
                        output += "f \(va) \(vb) \(vc)\n"
                    }
                }

                objectVertices += part.positions.count
                objectNormals += part.normals.count
            } }

            vertexBase += objectVertices
            normalBase += objectNormals
            totalVertices += objectVertices
            totalTriangles += mesh.triangleCount
        }

        try output.write(to: url, atomically: true, encoding: .utf8)
        return ExportSummary(
            objectCount: meshes.count, triangleCount: totalTriangles, vertexCount: totalVertices)
    }

    private static func fmt(_ value: CGFloat) -> String { MVRGeometryExport.format(value) }

    /// OBJ group names are whitespace-delimited, so spaces would split the
    /// name into stray tokens.
    private static func sanitized(_ name: String, fallbackIndex: Int) -> String {
        let cleaned = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return cleaned.isEmpty ? "object_\(fallbackIndex)" : cleaned
    }
}
