import Foundation
import SceneKit

enum MVROBJExportError: Error, LocalizedError {
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .nothingToExport:
            return "The selected objects contain no exportable geometry."
        }
    }
}

/// Writes selected scene geometry out as a Wavefront OBJ.
///
/// OBJ is chosen over FBX deliberately: it's a documented plain-text
/// format that can be written directly, whereas FBX is a proprietary
/// binary format with no macOS support, so it would mean a large
/// from-scratch implementation or a third-party dependency. OBJ carries
/// everything needed here — triangle geometry, normals, and per-object
/// grouping so pieces stay separable in Blender, Cinema 4D and friends.
///
/// Geometry is written in the viewer's own space: **metres, Y up**, which
/// is the usual interchange convention. Each scene object becomes an `o`
/// group.
enum MVROBJExporter {

    struct ExportItem {
        let node: SCNNode
        /// Becomes the OBJ `o` group name.
        let name: String
    }

    struct ExportSummary {
        let objectCount: Int
        let triangleCount: Int
        let vertexCount: Int
    }

    @discardableResult
    static func export(items: [ExportItem], to url: URL) throws -> ExportSummary {
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
        var exportedObjects = 0

        for (index, item) in items.enumerated() {
            var body = ""
            var objectVertices = 0
            var objectNormals = 0
            var objectTriangles = 0

            item.node.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry else { return }
                guard let positionSource = geometry.sources(for: .vertex).first else { return }

                let positions = readVectors(positionSource)
                guard !positions.isEmpty else { return }
                let normals = geometry.sources(for: .normal).first.map(readVectors) ?? []

                // Bake the node's placement in, so the exported file is a
                // single consistent world rather than a pile of parts all
                // sitting at the origin.
                let transform = node.worldTransform
                for position in positions {
                    let world = transformPoint(position, transform)
                    body += "v \(format(world.x)) \(format(world.y)) \(format(world.z))\n"
                }
                for normal in normals {
                    let world = normalize(transformDirection(normal, transform))
                    body += "vn \(format(world.x)) \(format(world.y)) \(format(world.z))\n"
                }

                let hasNormals = normals.count == positions.count
                for element in geometry.elements where element.primitiveType == .triangles {
                    let indices = readIndices(element)
                    var i = 0
                    while i + 2 < indices.count {
                        let a = indices[i], b = indices[i + 1], c = indices[i + 2]
                        i += 3
                        guard a < positions.count, b < positions.count, c < positions.count else { continue }
                        let va = vertexBase + objectVertices + a
                        let vb = vertexBase + objectVertices + b
                        let vc = vertexBase + objectVertices + c
                        if hasNormals {
                            let na = normalBase + objectNormals + a
                            let nb = normalBase + objectNormals + b
                            let nc = normalBase + objectNormals + c
                            body += "f \(va)//\(na) \(vb)//\(nb) \(vc)//\(nc)\n"
                        } else {
                            body += "f \(va) \(vb) \(vc)\n"
                        }
                        objectTriangles += 1
                    }
                }

                objectVertices += positions.count
                objectNormals += normals.count
            }

            guard objectTriangles > 0 else { continue }

            output += "o \(sanitized(item.name, fallbackIndex: index))\n"
            output += body
            vertexBase += objectVertices
            normalBase += objectNormals
            totalVertices += objectVertices
            totalTriangles += objectTriangles
            exportedObjects += 1
        }

        guard exportedObjects > 0 else { throw MVROBJExportError.nothingToExport }

        try output.write(to: url, atomically: true, encoding: .utf8)
        return ExportSummary(objectCount: exportedObjects, triangleCount: totalTriangles, vertexCount: totalVertices)
    }

    // MARK: - Geometry reading

    /// Reads a geometry source generically via its stride/offset rather
    /// than assuming a packed Float32 layout, so it stays correct for
    /// interleaved or Double-backed sources.
    private static func readVectors(_ source: SCNGeometrySource) -> [SCNVector3] {
        let count = source.vectorCount
        guard count > 0, source.componentsPerVector >= 3 else { return [] }
        let stride = source.dataStride
        let offset = source.dataOffset
        let bytesPerComponent = source.bytesPerComponent

        var result: [SCNVector3] = []
        result.reserveCapacity(count)

        source.data.withUnsafeBytes { raw in
            for i in 0..<count {
                let base = offset + i * stride
                guard base + bytesPerComponent * 3 <= raw.count else { break }
                switch bytesPerComponent {
                case 4:
                    let x = raw.loadUnaligned(fromByteOffset: base, as: Float.self)
                    let y = raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                    let z = raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
                    result.append(SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)))
                case 8:
                    let x = raw.loadUnaligned(fromByteOffset: base, as: Double.self)
                    let y = raw.loadUnaligned(fromByteOffset: base + 8, as: Double.self)
                    let z = raw.loadUnaligned(fromByteOffset: base + 16, as: Double.self)
                    result.append(SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)))
                default:
                    break
                }
            }
        }
        return result
    }

    private static func readIndices(_ element: SCNGeometryElement) -> [Int] {
        let count = element.primitiveCount * 3
        guard count > 0 else { return [] }
        let bytesPerIndex = element.bytesPerIndex
        var result: [Int] = []
        result.reserveCapacity(count)

        element.data.withUnsafeBytes { raw in
            for i in 0..<count {
                let base = i * bytesPerIndex
                guard base + bytesPerIndex <= raw.count else { break }
                switch bytesPerIndex {
                case 1: result.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt8.self)))
                case 2: result.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt16.self)))
                case 4: result.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt32.self)))
                case 8: result.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt64.self)))
                default: break
                }
            }
        }
        return result
    }

    // MARK: - Maths helpers

    /// SceneKit uses row-vector convention: v' = v * M, with translation
    /// in m41…m43.
    private static func transformPoint(_ v: SCNVector3, _ m: SCNMatrix4) -> SCNVector3 {
        SCNVector3(
            v.x * m.m11 + v.y * m.m21 + v.z * m.m31 + m.m41,
            v.x * m.m12 + v.y * m.m22 + v.z * m.m32 + m.m42,
            v.x * m.m13 + v.y * m.m23 + v.z * m.m33 + m.m43)
    }

    /// Directions ignore translation.
    private static func transformDirection(_ v: SCNVector3, _ m: SCNMatrix4) -> SCNVector3 {
        SCNVector3(
            v.x * m.m11 + v.y * m.m21 + v.z * m.m31,
            v.x * m.m12 + v.y * m.m22 + v.z * m.m32,
            v.x * m.m13 + v.y * m.m23 + v.z * m.m33)
    }

    private static func normalize(_ v: SCNVector3) -> SCNVector3 {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard length > 0 else { return SCNVector3(0, 1, 0) }
        return SCNVector3(v.x / length, v.y / length, v.z / length)
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.6f", Double(value))
    }

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
