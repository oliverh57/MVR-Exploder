import Foundation
import SceneKit

/// Reduces a triangle mesh to fewer triangles while keeping its shape, by
/// quadric edge collapse (Garland & Heckbert): every vertex carries the sum
/// of the squared distances to the planes of the faces around it, and the
/// edge whose collapse adds least to that error goes first, its two ends
/// merged at the point that keeps the error lowest.
///
/// Three things the textbook version leaves out matter on MVR meshes:
/// - **Welding first.** Scene `.3ds` meshes usually give every face its own
///   three vertices, so no edge is shared and nothing could collapse.
///   Coincident vertices are merged before anything else.
/// - **Open edges stay put.** Set pieces are often open shells; an edge
///   with a face on one side only gets a steep penalty plane so the
///   outline survives.
/// - **No flips.** A collapse that would turn a face over is refused, which
///   is what stops thin parts like truss tubes folding inside out.
nonisolated enum MeshSimplifier {

    struct Mesh {
        var positions: [SIMD3<Double>]
        /// Three per triangle.
        var indices: [Int]

        var triangleCount: Int { indices.count / 3 }
    }

    /// Meshes this small are left alone: there's nothing to gain, and a box
    /// has no triangle to spare.
    static let minimumTriangles = 12

    /// `mesh` reduced to about `fraction` of its triangles, never fewer
    /// than `minimumTriangles`. Stops early, above the target, once every
    /// remaining collapse would flip a face.
    static func simplify(_ mesh: Mesh, keeping fraction: Double) -> Mesh {
        let welded = weld(mesh)
        let target = max(Int((Double(mesh.triangleCount) * fraction).rounded()), minimumTriangles)
        guard welded.triangleCount > target, let first = welded.positions.first else { return welded }

        // Worked in a unit-sized copy, so the thresholds below mean the same
        // for a millimetre `.3ds` as for a metre `.glb`.
        var low = first, high = first
        for point in welded.positions {
            low = pointwiseMin(low, point)
            high = pointwiseMax(high, point)
        }
        let centre = (low + high) / 2
        let scale = max(simd_length(high - low), 1e-12)
        var unit = welded
        unit.positions = welded.positions.map { ($0 - centre) / scale }

        var collapser = Collapser(unit)
        collapser.run(targetTriangles: target)
        var result = collapser.result()
        result.positions = result.positions.map { $0 * scale + centre }
        return result
    }

    // MARK: - Welding

    /// Merges vertices closer than a millionth of the mesh's size, and
    /// drops the faces that leaves with a repeated corner.
    static func weld(_ mesh: Mesh) -> Mesh {
        guard let first = mesh.positions.first else { return mesh }
        var low = first, high = first
        for point in mesh.positions {
            low = pointwiseMin(low, point)
            high = pointwiseMax(high, point)
        }
        let size = high - low
        let tolerance = max((size * size).sum().squareRoot() * 1e-6, 1e-12)

        var remap = [Int](repeating: 0, count: mesh.positions.count)
        var cells: [SIMD3<Int64>: Int] = [:]
        var positions: [SIMD3<Double>] = []
        for (index, point) in mesh.positions.enumerated() {
            let cell = SIMD3<Int64>(
                Int64(((point.x - low.x) / tolerance).rounded()),
                Int64(((point.y - low.y) / tolerance).rounded()),
                Int64(((point.z - low.z) / tolerance).rounded()))
            if let existing = cells[cell] {
                remap[index] = existing
            } else {
                cells[cell] = positions.count
                remap[index] = positions.count
                positions.append(point)
            }
        }

        var indices: [Int] = []
        indices.reserveCapacity(mesh.indices.count)
        var corner = 0
        while corner + 2 < mesh.indices.count {
            let a = remap[mesh.indices[corner]], b = remap[mesh.indices[corner + 1]], c = remap[mesh.indices[corner + 2]]
            corner += 3
            guard a != b, b != c, a != c else { continue }
            indices += [a, b, c]
        }
        return Mesh(positions: positions, indices: indices)
    }

    // MARK: - Quadrics

    /// A symmetric 4×4 error quadric, its ten distinct entries.
    struct Quadric {
        var a = 0.0, b = 0.0, c = 0.0, d = 0.0
        var e = 0.0, f = 0.0, g = 0.0
        var h = 0.0, i = 0.0
        var j = 0.0

        /// The squared distance to the plane `n·p + offset = 0`, times
        /// `weight`.
        init(normal n: SIMD3<Double>, offset: Double, weight: Double) {
            a = n.x * n.x * weight; b = n.x * n.y * weight; c = n.x * n.z * weight; d = n.x * offset * weight
            e = n.y * n.y * weight; f = n.y * n.z * weight; g = n.y * offset * weight
            h = n.z * n.z * weight; i = n.z * offset * weight
            j = offset * offset * weight
        }

        init() {}

        static func + (l: Quadric, r: Quadric) -> Quadric {
            var q = Quadric()
            q.a = l.a + r.a; q.b = l.b + r.b; q.c = l.c + r.c; q.d = l.d + r.d
            q.e = l.e + r.e; q.f = l.f + r.f; q.g = l.g + r.g
            q.h = l.h + r.h; q.i = l.i + r.i
            q.j = l.j + r.j
            return q
        }

        func error(at p: SIMD3<Double>) -> Double {
            a * p.x * p.x + 2 * b * p.x * p.y + 2 * c * p.x * p.z + 2 * d * p.x
                + e * p.y * p.y + 2 * f * p.y * p.z + 2 * g * p.y
                + h * p.z * p.z + 2 * i * p.z
                + j
        }

        /// The point of least error, when the quadric pins one down.
        func minimum() -> SIMD3<Double>? {
            let det = a * (e * h - f * f) - b * (b * h - f * c) + c * (b * f - e * c)
            guard abs(det) > 1e-12 else { return nil }
            let x = -(d * (e * h - f * f) - b * (g * h - f * i) + c * (g * f - e * i)) / det
            let y = -(a * (g * h - i * f) - d * (b * h - f * c) + c * (b * i - g * c)) / det
            let z = -(a * (e * i - f * g) - b * (b * i - g * c) + d * (b * f - e * c)) / det
            return SIMD3(x, y, z)
        }
    }

    // MARK: - Collapse

    private struct Candidate {
        let cost: Double
        let from: Int
        let to: Int
        let fromVersion: Int
        let toVersion: Int
        let position: SIMD3<Double>
    }

    private struct Collapser {
        var positions: [SIMD3<Double>]
        var faces: [SIMD3<Int>]
        var faceAlive: [Bool]
        var facesOfVertex: [[Int]]
        var quadrics: [Quadric]
        var version: [Int]
        var vertexAlive: [Bool]
        var liveFaces: Int
        var heap = Heap()

        init(_ mesh: Mesh) {
            positions = mesh.positions
            faces = stride(from: 0, to: mesh.indices.count, by: 3).map {
                SIMD3(mesh.indices[$0], mesh.indices[$0 + 1], mesh.indices[$0 + 2])
            }
            faceAlive = [Bool](repeating: true, count: faces.count)
            liveFaces = faces.count
            facesOfVertex = [[Int]](repeating: [], count: positions.count)
            quadrics = [Quadric](repeating: Quadric(), count: positions.count)
            version = [Int](repeating: 0, count: positions.count)
            vertexAlive = [Bool](repeating: true, count: positions.count)

            var edgeFaces: [Edge: Int] = [:]
            for (index, face) in faces.enumerated() {
                for corner in 0..<3 { facesOfVertex[face[corner]].append(index) }
                guard let (normal, area) = normalAndArea(face) else { continue }
                let plane = Quadric(normal: normal, offset: -simd_dot(normal, positions[face.x]), weight: area)
                for corner in 0..<3 { quadrics[face[corner]] = quadrics[face[corner]] + plane }
                for corner in 0..<3 {
                    edgeFaces[Edge(face[corner], face[(corner + 1) % 3]), default: 0] += 1
                }
            }

            // Open edges: a plane through the edge, upright to its one
            // face, weighted heavily so the outline is the last thing to go.
            for face in faces {
                guard let (normal, area) = normalAndArea(face) else { continue }
                for corner in 0..<3 {
                    let u = face[corner], v = face[(corner + 1) % 3]
                    guard edgeFaces[Edge(u, v)] == 1 else { continue }
                    let along = positions[v] - positions[u]
                    let side = simd_cross(along, normal)
                    let length = simd_length(side)
                    guard length > 0 else { continue }
                    let n = side / length
                    let plane = Quadric(
                        normal: n, offset: -simd_dot(n, positions[u]),
                        weight: max(area, simd_length_squared(along)) * 1000)
                    quadrics[u] = quadrics[u] + plane
                    quadrics[v] = quadrics[v] + plane
                }
            }

            for edge in edgeFaces.keys { push(edge.low, edge.high) }
        }

        func normalAndArea(_ face: SIMD3<Int>) -> (SIMD3<Double>, Double)? {
            let cross = simd_cross(positions[face.y] - positions[face.x], positions[face.z] - positions[face.x])
            let length = simd_length(cross)
            guard length > 0 else { return nil }
            return (cross / length, length / 2)
        }

        mutating func push(_ u: Int, _ v: Int) {
            let q = quadrics[u] + quadrics[v]
            let midpoint = (positions[u] + positions[v]) / 2
            var best = q.minimum() ?? midpoint
            var cost = q.error(at: best)
            // A solved minimum far outside the edge is a sliver's doing,
            // not a better place; fall back to the edge itself.
            if !cost.isFinite || simd_length(best - midpoint) > simd_length(positions[u] - positions[v]) * 2 {
                cost = .infinity
            }
            for option in [positions[u], positions[v], midpoint] {
                let error = q.error(at: option)
                if error < cost { cost = error; best = option }
            }
            heap.push(Candidate(
                cost: max(cost, 0), from: v, to: u,
                fromVersion: version[v], toVersion: version[u], position: best))
        }

        mutating func run(targetTriangles: Int) {
            while liveFaces > targetTriangles, let candidate = heap.pop() {
                let u = candidate.to, v = candidate.from
                guard vertexAlive[u], vertexAlive[v],
                      version[u] == candidate.toVersion, version[v] == candidate.fromVersion
                else { continue }
                guard !flips(merging: v, into: u, at: candidate.position) else { continue }
                collapse(v, into: u, at: candidate.position)
            }
        }

        /// Whether moving `u` and `v` to `p` would turn any surviving face
        /// over or squash it flat.
        func flips(merging v: Int, into u: Int, at p: SIMD3<Double>) -> Bool {
            for vertex in [u, v] {
                for faceIndex in facesOfVertex[vertex] where faceAlive[faceIndex] {
                    let face = faces[faceIndex]
                    let hasU = face.x == u || face.y == u || face.z == u
                    let hasV = face.x == v || face.y == v || face.z == v
                    if hasU && hasV { continue }  // goes with the edge
                    guard let (before, _) = normalAndArea(face) else { continue }
                    var moved = [positions[face.x], positions[face.y], positions[face.z]]
                    for corner in 0..<3 where face[corner] == vertex { moved[corner] = p }
                    let cross = simd_cross(moved[1] - moved[0], moved[2] - moved[0])
                    let length = simd_length(cross)
                    if length < 1e-15 || simd_dot(cross / length, before) < 0.2 { return true }
                }
            }
            return false
        }

        mutating func collapse(_ v: Int, into u: Int, at p: SIMD3<Double>) {
            positions[u] = p
            quadrics[u] = quadrics[u] + quadrics[v]
            vertexAlive[v] = false
            version[u] += 1
            version[v] += 1

            for faceIndex in facesOfVertex[v] where faceAlive[faceIndex] {
                var face = faces[faceIndex]
                if face.x == u || face.y == u || face.z == u {
                    faceAlive[faceIndex] = false
                    liveFaces -= 1
                    continue
                }
                for corner in 0..<3 where face[corner] == v { face[corner] = u }
                faces[faceIndex] = face
                facesOfVertex[u].append(faceIndex)
            }
            facesOfVertex[v] = []
            facesOfVertex[u].removeAll { !faceAlive[$0] }

            var neighbours = Set<Int>()
            for faceIndex in facesOfVertex[u] {
                let face = faces[faceIndex]
                for corner in 0..<3 where face[corner] != u { neighbours.insert(face[corner]) }
            }
            for neighbour in neighbours { push(u, neighbour) }
        }

        func result() -> Mesh {
            var remap = [Int](repeating: -1, count: positions.count)
            var out: [SIMD3<Double>] = []
            var indices: [Int] = []
            for (index, face) in faces.enumerated() where faceAlive[index] {
                for corner in 0..<3 {
                    let vertex = face[corner]
                    if remap[vertex] < 0 {
                        remap[vertex] = out.count
                        out.append(positions[vertex])
                    }
                    indices.append(remap[vertex])
                }
            }
            return Mesh(positions: out, indices: indices)
        }
    }

    private struct Edge: Hashable {
        let low: Int
        let high: Int
        init(_ a: Int, _ b: Int) { low = min(a, b); high = max(a, b) }
    }

    /// A binary min-heap on cost.
    private struct Heap {
        private var items: [Candidate] = []

        mutating func push(_ item: Candidate) {
            items.append(item)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].cost < items[parent].cost else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> Candidate? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].cost < items[smallest].cost { smallest = left }
                if right < items.count, items[right].cost < items[smallest].cost { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
            return top
        }
    }
}

// MARK: - Mesh files

/// Reading a scene mesh file in its own units and axes, and writing one
/// back in the same format — so a simplified mesh replaces the original
/// file byte-for-byte in kind, and every reference to it stays valid.
nonisolated enum MeshFile {

    /// The mesh in `data`, in the file's own space: millimetres Z-up for
    /// `.3ds`, metres Y-up for `.glb`. Nil for a format this can't write
    /// back.
    static func read(_ data: Data, fileName: String) -> MeshSimplifier.Mesh? {
        let name = fileName.lowercased()
        if name.hasSuffix(".3ds") {
            guard let raw = GDTF3DSParser.parse(data) else { return nil }
            return MeshSimplifier.Mesh(
                positions: raw.vertices.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) },
                indices: raw.faceIndices.map(Int.init))
        }
        if name.hasSuffix(".glb") {
            guard let root = GLBParser.parse(data) else { return nil }
            var positions: [SIMD3<Double>] = []
            var indices: [Int] = []
            root.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry,
                      let source = geometry.sources(for: .vertex).first else { return }
                let points = SCNGeometryMerge.readVectors(source)
                let base = positions.count
                for point in points {
                    let placed = SCNGeometryMerge.transformPoint(point, node.worldTransform)
                    positions.append(SIMD3(Double(placed.x), Double(placed.y), Double(placed.z)))
                }
                for element in geometry.elements where element.primitiveType == .triangles {
                    let read = SCNGeometryMerge.readIndices(element)
                    guard read.allSatisfy({ $0 >= 0 && $0 < points.count }) else { continue }
                    indices += read.map { base + $0 }
                }
            }
            return indices.isEmpty ? nil : MeshSimplifier.Mesh(positions: positions, indices: indices)
        }
        return nil
    }

    static func write(_ mesh: MeshSimplifier.Mesh, fileName: String) -> Data? {
        let name = fileName.lowercased()
        if name.hasSuffix(".3ds") { return write3DS(mesh) }
        if name.hasSuffix(".glb") { return writeGLB(mesh) }
        return nil
    }

    // MARK: Materials

    /// The diffuse colours a mesh file's materials define, as 0xRRGGBB.
    /// Material *names* are no use for matching — Vectorworks numbers them
    /// per file, so every mesh has a "Material_0" — but their colours are
    /// what the designer picked: 11 to 31 distinct ones across real files.
    static func materialColours(_ data: Data, fileName: String) -> Set<UInt32> {
        let name = fileName.lowercased()
        if name.hasSuffix(".3ds") { return colours3DS([UInt8](data)) }
        if name.hasSuffix(".glb") { return coloursGLB([UInt8](data)) }
        return []
    }

    private static func colours3DS(_ bytes: [UInt8]) -> Set<UInt32> {
        func uint16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func uint32(_ at: Int) -> Int { uint16(at) | uint16(at + 2) << 16 }
        func float(_ at: Int) -> Float { Float(bitPattern: UInt32(uint32(at))) }
        func pack(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
            UInt32(max(0, min(255, r))) << 16 | UInt32(max(0, min(255, g))) << 8 | UInt32(max(0, min(255, b)))
        }

        /// A 0…1 float as 0…255; anything a file gets wrong — NaN, huge —
        /// is clamped rather than trapping.
        func byte(_ value: Float) -> Int {
            value.isFinite ? Int(max(0, min(255, value * 255))) : 0
        }

        var found: Set<UInt32> = []
        /// The first colour inside a diffuse-colour chunk: bytes or floats,
        /// with or without gamma.
        func colour(_ start: Int, _ end: Int) -> UInt32? {
            var offset = start
            while offset + 6 <= end {
                let id = uint16(offset), length = uint32(offset + 2)
                guard length >= 6, offset + length <= end else { return nil }
                switch id {
                case 0x0011, 0x0012:
                    guard offset + 9 <= end else { return nil }
                    return pack(Int(bytes[offset + 6]), Int(bytes[offset + 7]), Int(bytes[offset + 8]))
                case 0x0010, 0x0013:
                    guard offset + 18 <= end else { return nil }
                    return pack(byte(float(offset + 6)), byte(float(offset + 10)), byte(float(offset + 14)))
                default:
                    offset += length
                }
            }
            return nil
        }
        func walk(_ start: Int, _ end: Int) {
            var offset = start
            while offset + 6 <= end {
                let id = uint16(offset), length = uint32(offset + 2)
                guard length >= 6, offset + length <= end else { return }
                switch id {
                case 0x4D4D, 0x3D3D, 0xAFFF: walk(offset + 6, offset + length)
                case 0xA020: if let value = colour(offset + 6, offset + length) { found.insert(value) }
                default: break
                }
                offset += length
            }
        }
        walk(0, bytes.count)
        return found
    }

    private static func coloursGLB(_ bytes: [UInt8]) -> Set<UInt32> {
        guard bytes.count > 20 else { return [] }
        let length = Int(bytes[12]) | Int(bytes[13]) << 8 | Int(bytes[14]) << 16 | Int(bytes[15]) << 24
        guard 20 + length <= bytes.count,
              let json = try? JSONSerialization.jsonObject(with: Data(bytes[20..<20 + length])) as? [String: Any]
        else { return [] }
        var found: Set<UInt32> = []
        for material in json["materials"] as? [[String: Any]] ?? [] {
            let pbr = material["pbrMetallicRoughness"] as? [String: Any]
            let factor = (pbr?["baseColorFactor"] as? [Double]) ?? [1, 1, 1, 1]
            guard factor.count >= 3 else { continue }
            let channel = { (value: Double) in value.isFinite ? UInt32(max(0, min(255, (value * 255).rounded()))) : 0 }
            found.insert(channel(factor[0]) << 16 | channel(factor[1]) << 8 | channel(factor[2]))
        }
        return found
    }

    // MARK: .3ds

    /// A `.3ds` holds at most 65,535 vertices and faces per object, so a
    /// bigger mesh is written as several objects.
    private static func write3DS(_ mesh: MeshSimplifier.Mesh) -> Data {
        var objects = Data()
        var objectCount = 0
        var remap: [Int: UInt16] = [:]
        var vertices: [SIMD3<Double>] = []
        var faces: [UInt16] = []

        func flush() {
            guard !faces.isEmpty else { return }
            var vertexBody = little(UInt16(vertices.count))
            for v in vertices {
                vertexBody += little(Float(v.x).bitPattern)
                vertexBody += little(Float(v.y).bitPattern)
                vertexBody += little(Float(v.z).bitPattern)
            }
            var faceBody = little(UInt16(faces.count / 3))
            for corner in stride(from: 0, to: faces.count, by: 3) {
                faceBody += little(faces[corner]) + little(faces[corner + 1]) + little(faces[corner + 2]) + little(UInt16(0))
            }
            let triMesh = chunk(0x4100, chunk(0x4110, vertexBody) + chunk(0x4120, faceBody))
            objectCount += 1
            let name = Data("mesh\(objectCount)".utf8) + Data([0])
            objects += chunk(0x4000, name + triMesh)
            remap = [:]
            vertices = []
            faces = []
        }

        for corner in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let triangle = [mesh.indices[corner], mesh.indices[corner + 1], mesh.indices[corner + 2]]
            let newVertices = triangle.filter { remap[$0] == nil }.count
            if vertices.count + newVertices > 65_535 || faces.count / 3 >= 65_535 { flush() }
            for vertex in triangle {
                if let local = remap[vertex] {
                    faces.append(local)
                } else {
                    let local = UInt16(vertices.count)
                    remap[vertex] = local
                    vertices.append(mesh.positions[vertex])
                    faces.append(local)
                }
            }
        }
        flush()

        let version = chunk(0x0002, little(UInt32(3)))
        let meshVersion = chunk(0x3D3E, little(UInt32(3)))
        return chunk(0x4D4D, version + chunk(0x3D3D, meshVersion + objects))
    }

    private static func chunk(_ id: UInt16, _ body: Data) -> Data {
        little(id) + little(UInt32(body.count + 6)) + body
    }

    private static func little<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // MARK: .glb

    /// One mesh, one node, positions and 32-bit indices: the subset
    /// `GLBParser` reads and every glTF importer accepts.
    private static func writeGLB(_ mesh: MeshSimplifier.Mesh) -> Data? {
        guard let first = mesh.positions.first else { return nil }
        var low = SIMD3<Float>(first), high = SIMD3<Float>(first)
        var binary = Data()
        for point in mesh.positions {
            let p = SIMD3<Float>(point)
            low = pointwiseMin(low, p)
            high = pointwiseMax(high, p)
            binary += little(p.x.bitPattern) + little(p.y.bitPattern) + little(p.z.bitPattern)
        }
        let positionBytes = binary.count
        for index in mesh.indices { binary += little(UInt32(index)) }
        let indexBytes = binary.count - positionBytes
        while binary.count % 4 != 0 { binary.append(0) }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "MVR Exploder"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1, "mode": 4]]]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": mesh.positions.count, "type": "VEC3",
                 "min": [low.x, low.y, low.z], "max": [high.x, high.y, high.z]],
                ["bufferView": 1, "componentType": 5125, "count": mesh.indices.count, "type": "SCALAR"],
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": positionBytes, "target": 34962],
                ["buffer": 0, "byteOffset": positionBytes, "byteLength": indexBytes, "target": 34963],
            ],
            "buffers": [["byteLength": binary.count]],
        ]
        guard var jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return nil }
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var file = Data()
        file += little(UInt32(0x46546C67))  // 'glTF'
        file += little(UInt32(2))
        file += little(UInt32(12 + 8 + jsonData.count + 8 + binary.count))
        file += little(UInt32(jsonData.count)) + little(UInt32(0x4E4F534A)) + jsonData
        file += little(UInt32(binary.count)) + little(UInt32(0x004E4942)) + binary
        return file
    }
}
