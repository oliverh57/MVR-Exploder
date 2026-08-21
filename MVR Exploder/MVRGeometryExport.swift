import Foundation
import SceneKit

enum MVRGeometryExportError: Error, LocalizedError {
    case nothingToExport
    case cannotCreateFile(URL)

    var errorDescription: String? {
        switch self {
        case .nothingToExport:
            return "The selected objects contain no exportable geometry."
        case let .cannotCreateFile(url):
            return "Couldn't write to \(url.lastPathComponent)."
        }
    }
}

/// Reads selected scene objects out of the viewer's SceneKit tree into
/// plain arrays, so each file format only has to worry about serialising.
///
/// Shared because pulling triangles out of an `SCNGeometry` is the fiddly
/// part — sources can be interleaved, `Double`-backed, or indexed with any
/// of four integer widths — and having three exporters each get that right
/// separately is three chances to get it wrong.
///
/// Everything comes out in the viewer's own space: **metres, Y up**, with
/// each node's placement baked in, so what a writer receives is one
/// consistent world rather than a pile of parts at the origin.
enum MVRGeometryExport {

    struct ExportItem {
        let node: SCNNode
        /// Becomes the object/group/layer name in the exported file.
        let name: String
    }

    struct ExportSummary {
        let objectCount: Int
        let triangleCount: Int
        let vertexCount: Int
    }

    /// The formats the viewer can write.
    ///
    /// Three, because they answer three different questions: OBJ to get
    /// geometry into anything at all, FBX to take it into a DCC with the
    /// scene tree intact, DXF to put it in front of a CAD package.
    enum Format: String, CaseIterable, Identifiable {
        case obj, fbx, dxf

        var id: String { rawValue }
        var fileExtension: String { rawValue }

        var label: String {
            switch self {
            case .obj: return "Wavefront OBJ"
            case .fbx: return "Autodesk FBX"
            case .dxf: return "AutoCAD DXF"
            }
        }

        /// What the user gets, in the terms they'd choose it by.
        var detail: String {
            switch self {
            case .obj: return "Reads everywhere. Metres, Y up."
            case .fbx: return "Blender, Cinema 4D, Maya. Centimetres, Y up."
            case .dxf: return "AutoCAD, Vectorworks, Rhino. Metres, Z up, one layer per object."
            }
        }
    }

    @discardableResult
    static func export(items: [ExportItem], as format: Format, to url: URL) throws -> ExportSummary {
        switch format {
        case .obj: return try MVROBJExporter.export(items: items, to: url)
        case .fbx: return try MVRFBXExporter.export(items: items, to: url)
        case .dxf: return try MVRDXFExporter.export(items: items, to: url)
        }
    }

    /// One selected object, flattened.
    struct Mesh {
        let name: String
        /// The object's index in the original selection, for naming a
        /// nameless one.
        let index: Int
        /// Kept split by source node rather than concatenated: a node
        /// carrying no normals sits happily beside one that does, and
        /// merging them would mean either inventing normals or throwing
        /// away the ones we have.
        var parts: [Part]

        var triangleCount: Int { parts.reduce(0) { $0 + $1.triangles.count } }
        var vertexCount: Int { parts.reduce(0) { $0 + $1.positions.count } }
        /// True only when every part has them, since a format writing one
        /// normal layer for the whole object can't have half of it missing.
        var hasNormals: Bool { parts.allSatisfy { $0.normals.count == $0.positions.count } }
    }

    struct Part {
        var positions: [SCNVector3]
        /// Empty, or exactly as many as there are positions.
        var normals: [SCNVector3]
        /// Indices into this part's own `positions`.
        var triangles: [(a: Int, b: Int, c: Int)]
    }

    /// Walks the selection and pulls out everything with triangles.
    /// Objects that turn out to hold none are dropped rather than written
    /// as empties.
    static func meshes(for items: [ExportItem]) -> [Mesh] {
        var result: [Mesh] = []

        for (index, item) in items.enumerated() {
            var parts: [Part] = []

            // Reading a geometry source leaves autoreleased objects behind
            // too, and a whole-venue selection walks millions of vertices
            // before the export's own pool would drain.
            autoreleasepool {
            item.node.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry,
                      let positionSource = geometry.sources(for: .vertex).first else { return }

                let positions = readVectors(positionSource)
                guard !positions.isEmpty else { return }
                let normals = geometry.sources(for: .normal).first.map(readVectors) ?? []

                let transform = node.worldTransform
                var part = Part(
                    positions: positions.map { transformPoint($0, transform) },
                    normals: normals.count == positions.count
                        ? normals.map { normalize(transformDirection($0, transform)) }
                        : [],
                    triangles: [])

                for element in geometry.elements where element.primitiveType == .triangles {
                    let indices = readIndices(element)
                    var i = 0
                    while i + 2 < indices.count {
                        let (a, b, c) = (indices[i], indices[i + 1], indices[i + 2])
                        i += 3
                        guard a < positions.count, b < positions.count, c < positions.count else { continue }
                        part.triangles.append((a, b, c))
                    }
                }

                // Kept even with no triangles of its own: the original
                // exporter counted every vertex it read towards the
                // object's index base, and a part dropped here would shift
                // every index after it.
                parts.append(part)
            }
            }

            guard parts.contains(where: { !$0.triangles.isEmpty }) else { continue }
            result.append(Mesh(name: item.name, index: index, parts: parts))
        }

        return result
    }

    // MARK: - Geometry reading

    /// Reads a geometry source generically via its stride/offset rather
    /// than assuming a packed Float32 layout, so it stays correct for
    /// interleaved or Double-backed sources.
    static func readVectors(_ source: SCNGeometrySource) -> [SCNVector3] {
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

    static func readIndices(_ element: SCNGeometryElement) -> [Int] {
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
    static func transformPoint(_ v: SCNVector3, _ m: SCNMatrix4) -> SCNVector3 {
        SCNVector3(
            v.x * m.m11 + v.y * m.m21 + v.z * m.m31 + m.m41,
            v.x * m.m12 + v.y * m.m22 + v.z * m.m32 + m.m42,
            v.x * m.m13 + v.y * m.m23 + v.z * m.m33 + m.m43)
    }

    /// Directions ignore translation.
    static func transformDirection(_ v: SCNVector3, _ m: SCNMatrix4) -> SCNVector3 {
        SCNVector3(
            v.x * m.m11 + v.y * m.m21 + v.z * m.m31,
            v.x * m.m12 + v.y * m.m22 + v.z * m.m32,
            v.x * m.m13 + v.y * m.m23 + v.z * m.m33)
    }

    static func normalize(_ v: SCNVector3) -> SCNVector3 {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard length > 0 else { return SCNVector3(0, 1, 0) }
        return SCNVector3(v.x / length, v.y / length, v.z / length)
    }

    static func format(_ value: CGFloat) -> String {
        String(format: "%.6f", Double(value))
    }
}
