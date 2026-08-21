import Foundation
import SceneKit

/// Concatenating many small meshes into one geometry, plus the buffer
/// reading it needs.
///
/// Both halves of the 3D view are draw-call bound rather than triangle
/// bound, for the same underlying reason: the source data is authored as a
/// great many separate small meshes. A CAD-exported venue arrives as tens of
/// thousands of individual `.3ds` files, and a GDTF pixel bar carries one
/// mesh per pixel — 382 of them on a real fixture, times every instance of
/// it in the rig. The triangles are trivial for a GPU; issuing a draw call
/// each is what makes navigation crawl.
enum SCNGeometryMerge {

    /// A box with **real-size vertex data**, unlike `SCNBox`.
    ///
    /// SceneKit's parametric geometries keep a *unit* vertex buffer and
    /// apply their real dimensions later, at render time: `SCNBox(width: 2,
    /// height: 3, length: 4)` reports a bounding box of 2×3×4 but its vertex
    /// source measures 1×1×1 (verified). That's invisible while SceneKit
    /// draws the shape itself, but anything that reads the vertices —
    /// merging here, or OBJ export — gets a unit cube, which is how every
    /// box-fallback fixture part once merged into a 1-metre block. Building
    /// the mesh explicitly keeps the geometry honest for every consumer.
    static func boxGeometry(width: CGFloat, height: CGFloat, length: CGFloat) -> SCNGeometry {
        let x = width / 2, y = height / 2, z = length / 2

        // Four corners per face, so each face can carry its own normal
        // rather than smoothing across the edges.
        let faces: [(normal: SCNVector3, corners: [SCNVector3])] = [
            (SCNVector3(1, 0, 0), [SCNVector3(x, -y, -z), SCNVector3(x, -y, z), SCNVector3(x, y, z), SCNVector3(x, y, -z)]),
            (SCNVector3(-1, 0, 0), [SCNVector3(-x, -y, z), SCNVector3(-x, -y, -z), SCNVector3(-x, y, -z), SCNVector3(-x, y, z)]),
            (SCNVector3(0, 1, 0), [SCNVector3(-x, y, -z), SCNVector3(x, y, -z), SCNVector3(x, y, z), SCNVector3(-x, y, z)]),
            (SCNVector3(0, -1, 0), [SCNVector3(-x, -y, z), SCNVector3(x, -y, z), SCNVector3(x, -y, -z), SCNVector3(-x, -y, -z)]),
            (SCNVector3(0, 0, 1), [SCNVector3(-x, -y, z), SCNVector3(-x, y, z), SCNVector3(x, y, z), SCNVector3(x, -y, z)]),
            (SCNVector3(0, 0, -1), [SCNVector3(x, -y, -z), SCNVector3(x, y, -z), SCNVector3(-x, y, -z), SCNVector3(-x, -y, -z)]),
        ]

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        for face in faces {
            let base = Int32(positions.count)
            positions.append(contentsOf: face.corners)
            normals.append(contentsOf: Array(repeating: face.normal, count: 4))
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }

        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// Flattens every mesh under `root` into a single geometry, baking each
    /// node's placement relative to `root` into the vertices. Returns nil if
    /// the tree holds nothing drawable.
    ///
    /// Normals are kept only when *every* contributing mesh has them, so the
    /// merge can never invent shading that wasn't there before.
    static func merged(tree root: SCNNode) -> SCNGeometry? {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        var hasNormals = true
        var material: SCNMaterial?

        let rootInverse = SCNMatrix4Invert(root.worldTransform)

        root.enumerateHierarchy { node, _ in
            guard
                let geometry = node.geometry,
                let positionSource = geometry.sources(for: .vertex).first
            else { return }
            let points = readVectors(positionSource)
            guard !points.isEmpty else { return }

            // Safety net for the unit-buffer behaviour described on
            // `boxGeometry`: if a geometry's vertices disagree with the size
            // it reports, trust the reported size. For an ordinary mesh the
            // bounding box is derived from these very vertices, so this is a
            // no-op; for a parametric shape it rescales the unit buffer to
            // what SceneKit would actually have drawn.
            let placement = SCNMatrix4Mult(
                SCNMatrix4Mult(unitBufferCorrection(for: geometry, points: points), node.worldTransform),
                rootInverse)
            let base = Int32(positions.count)

            // Gathered before appending anything, so a mesh with a bad index
            // is skipped whole rather than half-merged.
            var meshIndices: [Int32] = []
            for element in geometry.elements where element.primitiveType == .triangles {
                let read = readIndices(element)
                guard read.allSatisfy({ $0 >= 0 && $0 < points.count }) else { continue }
                meshIndices.append(contentsOf: read.map { base + Int32($0) })
            }
            guard !meshIndices.isEmpty else { return }

            for point in points { positions.append(transformPoint(point, placement)) }

            let sourceNormals = geometry.sources(for: .normal).first.map(readVectors) ?? []
            if hasNormals, sourceNormals.count == points.count {
                for normal in sourceNormals {
                    normals.append(normalize(transformDirection(normal, placement)))
                }
            } else {
                hasNormals = false
            }

            indices.append(contentsOf: meshIndices)
            if material == nil { material = geometry.firstMaterial }
        }

        guard positions.count >= 3, indices.count >= 3 else { return nil }

        var sources = [SCNGeometrySource(vertices: positions)]
        if hasNormals, normals.count == positions.count {
            sources.append(SCNGeometrySource(normals: normals))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        if let material { geometry.materials = [material] }
        return geometry
    }

    /// Scale that maps a geometry's raw vertices onto the size it reports
    /// through `boundingBox`, or identity when they already agree.
    private static func unitBufferCorrection(for geometry: SCNGeometry, points: [SCNVector3]) -> SCNMatrix4 {
        guard let first = points.first else { return SCNMatrix4Identity }
        var low = first, high = first
        for point in points {
            low = SCNVector3(min(low.x, point.x), min(low.y, point.y), min(low.z, point.z))
            high = SCNVector3(max(high.x, point.x), max(high.y, point.y), max(high.z, point.z))
        }

        let reported = geometry.boundingBox
        func factor(_ reportedSpan: CGFloat, _ actualSpan: CGFloat) -> CGFloat {
            // Flat axes (a zero-thickness plate) carry no scale information.
            guard actualSpan > 1e-9, reportedSpan > 1e-9 else { return 1 }
            let ratio = reportedSpan / actualSpan
            return abs(ratio - 1) < 0.01 ? 1 : ratio
        }

        let scale = SCNVector3(
            factor(reported.max.x - reported.min.x, high.x - low.x),
            factor(reported.max.y - reported.min.y, high.y - low.y),
            factor(reported.max.z - reported.min.z, high.z - low.z))
        guard scale.x != 1 || scale.y != 1 || scale.z != 1 else { return SCNMatrix4Identity }
        return SCNMatrix4MakeScale(scale.x, scale.y, scale.z)
    }

    // MARK: - Geometry buffer reading

    /// Reads a geometry source via its stride/offset rather than assuming a
    /// packed Float32 layout. This is not defensive padding: SceneKit's own
    /// parametric geometries are interleaved (`SCNBox` reports a stride of
    /// 32 with positions and normals in one buffer), so a packed-layout
    /// assumption would silently misread every box-fallback fixture.
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

    /// SceneKit uses the row-vector convention: v' = v * M, with translation
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
}
