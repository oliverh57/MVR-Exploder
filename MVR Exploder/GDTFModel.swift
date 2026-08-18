import Foundation
import SceneKit
import ZIPFoundation

/// Parses the small subset of the legacy Autodesk .3ds chunk format that
/// GDTF model files use (a single triangle mesh — no materials, UVs, or
/// animation are needed here). GDTF's .3ds meshes are unit-normalized; the
/// real physical size comes from the corresponding <Model> XML's
/// Width/Height/Length, applied later by `RawMesh.buildGeometry`.
enum GDTF3DSParser {
    struct RawMesh {
        let vertices: [SCNVector3]
        let faceIndices: [Int32]   // flat triangle list, 3 indices per face
    }

    private static let mainChunk: UInt16 = 0x4D4D
    private static let editor3DChunk: UInt16 = 0x3D3D
    private static let namedObjectChunk: UInt16 = 0x4000
    private static let triMeshChunk: UInt16 = 0x4100
    private static let vertexListChunk: UInt16 = 0x4110
    private static let faceListChunk: UInt16 = 0x4120

    static func parse(_ data: Data) -> RawMesh? {
        let bytes = [UInt8](data)
        var vertices: [SCNVector3] = []
        var faceIndices: [Int32] = []

        func readUInt16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
        func readFloat(_ offset: Int) -> Float {
            Float(bitPattern: readUInt32(offset))
        }

        func walk(_ start: Int, _ end: Int) {
            var offset = start
            while offset + 6 <= end {
                let chunkID = readUInt16(offset)
                let chunkLength = Int(readUInt32(offset + 2))
                guard chunkLength >= 6, offset + chunkLength <= end else { break }
                let bodyStart = offset + 6
                let bodyEnd = offset + chunkLength

                switch chunkID {
                case mainChunk, editor3DChunk, triMeshChunk:
                    walk(bodyStart, bodyEnd)

                case namedObjectChunk:
                    // Body starts with a null-terminated object name before
                    // any sub-chunks.
                    var nameEnd = bodyStart
                    while nameEnd < bodyEnd, bytes[nameEnd] != 0 { nameEnd += 1 }
                    walk(nameEnd + 1, bodyEnd)

                case vertexListChunk:
                    guard bodyStart + 2 <= bodyEnd else { break }
                    let count = Int(readUInt16(bodyStart))
                    var cursor = bodyStart + 2
                    for _ in 0..<count {
                        guard cursor + 12 <= bodyEnd else { break }
                        let x = readFloat(cursor), y = readFloat(cursor + 4), z = readFloat(cursor + 8)
                        vertices.append(SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)))
                        cursor += 12
                    }

                case faceListChunk:
                    guard bodyStart + 2 <= bodyEnd else { break }
                    let count = Int(readUInt16(bodyStart))
                    var cursor = bodyStart + 2
                    for _ in 0..<count {
                        guard cursor + 8 <= bodyEnd else { break }
                        faceIndices.append(Int32(readUInt16(cursor)))
                        faceIndices.append(Int32(readUInt16(cursor + 2)))
                        faceIndices.append(Int32(readUInt16(cursor + 4)))
                        cursor += 8
                    }

                default:
                    break
                }
                offset = bodyEnd
            }
        }

        walk(0, bytes.count)
        guard !vertices.isEmpty, !faceIndices.isEmpty else { return nil }
        return RawMesh(vertices: vertices, faceIndices: faceIndices)
    }
}

extension GDTF3DSParser.RawMesh {
    /// Builds an SCNGeometry scaled independently per axis to fit the given
    /// real-world width/length/height (meters), and remapped from the
    /// mesh's native axes (3ds Max convention: X=width, Y=depth, Z=up) into
    /// this app's scene convention (Y=up), matching the remap already used
    /// for fixture positions elsewhere in Fixture3DView. Centered on its
    /// own bounding-box middle so the caller can position it purely via a
    /// translation offset.
    func buildGeometry(width: Double, length: Double, height: Double) -> SCNGeometry? {
        guard !vertices.isEmpty else { return nil }

        let xs = vertices.map(\.x), ys = vertices.map(\.y), zs = vertices.map(\.z)
        guard
            let minX = xs.min(), let maxX = xs.max(),
            let minY = ys.min(), let maxY = ys.max(),
            let minZ = zs.min(), let maxZ = zs.max()
        else { return nil }

        let extentX = maxX - minX, extentY = maxY - minY, extentZ = maxZ - minZ
        guard extentX > 0, extentY > 0, extentZ > 0 else { return nil }

        let centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2, centerZ = (minZ + maxZ) / 2
        let scaleX = CGFloat(width) / extentX
        let scaleY = CGFloat(length) / extentY
        let scaleZ = CGFloat(height) / extentZ

        let remapped = vertices.map { v -> SCNVector3 in
            let lx = (v.x - centerX) * scaleX
            let ly = (v.y - centerY) * scaleY
            let lz = (v.z - centerZ) * scaleZ
            return SCNVector3(lx, lz, -ly)
        }

        var normals = [SCNVector3](repeating: SCNVector3Zero, count: remapped.count)
        var i = 0
        while i + 2 < faceIndices.count {
            let ia = Int(faceIndices[i]), ib = Int(faceIndices[i + 1]), ic = Int(faceIndices[i + 2])
            defer { i += 3 }
            guard ia < remapped.count, ib < remapped.count, ic < remapped.count else { continue }
            let a = remapped[ia], b = remapped[ib], c = remapped[ic]
            let e1 = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z)
            let e2 = SCNVector3(c.x - a.x, c.y - a.y, c.z - a.z)
            let n = SCNVector3(
                e1.y * e2.z - e1.z * e2.y,
                e1.z * e2.x - e1.x * e2.z,
                e1.x * e2.y - e1.y * e2.x
            )
            for idx in [ia, ib, ic] {
                normals[idx] = SCNVector3(normals[idx].x + n.x, normals[idx].y + n.y, normals[idx].z + n.z)
            }
        }
        normals = normals.map { n in
            let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
            return len > 0 ? SCNVector3(n.x / len, n.y / len, n.z / len) : SCNVector3(0, 1, 0)
        }

        let vertexSource = SCNGeometrySource(vertices: remapped)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: faceIndices, primitiveType: .triangles)
        return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    }
}

/// One node in a GDTF fixture's geometry tree. GDTF mixes several element
/// tags in this tree (`Geometry`, `Axis`, `Beam`, ...) — any element with a
/// `Position` is treated uniformly here rather than special-cased by tag
/// name, since only the position/model-reference matter for a static
/// viewer.
struct GDTFGeometryNode {
    let modelName: String?
    /// Translation only, already remapped into scene (Y-up) axes. Rotation
    /// in <Geometry Position> matrices is not applied yet — parts are
    /// stacked axis-aligned, matching the existing translation-only
    /// handling of a fixture's own top-level <Matrix> (see
    /// MVRFixture.position3D).
    let localOffset: SCNVector3
    let children: [GDTFGeometryNode]
}

struct GDTFModelInfo {
    let width: Double
    let height: Double
    let length: Double
    let meshFileName: String?
}

struct GDTFAssembly {
    let roots: [GDTFGeometryNode]
    let models: [String: GDTFModelInfo]
    let meshes: [String: GDTF3DSParser.RawMesh]
}

enum GDTFAssemblyParser {
    /// Parses a raw .gdtf package's description.xml into its geometry tree
    /// plus every referenced .3ds mesh that could be found and parsed.
    static func parse(packageData data: Data) -> GDTFAssembly? {
        guard let archive = try? Archive(data: data, accessMode: .read) else { return nil }
        guard let descriptionEntry = archive.first(where: { ($0.path as NSString).lastPathComponent == "description.xml" }) else { return nil }

        var xmlData = Data()
        _ = try? archive.extract(descriptionEntry) { xmlData.append($0) }
        guard let document = try? XMLDocument(data: xmlData, options: []) else { return nil }

        var models: [String: GDTFModelInfo] = [:]
        for case let element as XMLElement in (try? document.nodes(forXPath: "//Models/Model")) ?? [] {
            guard let name = element.attribute(forName: "Name")?.stringValue else { continue }
            models[name] = GDTFModelInfo(
                width: element.attribute(forName: "Width")?.stringValue.flatMap(Double.init) ?? 0,
                height: element.attribute(forName: "Height")?.stringValue.flatMap(Double.init) ?? 0,
                length: element.attribute(forName: "Length")?.stringValue.flatMap(Double.init) ?? 0,
                meshFileName: element.attribute(forName: "File")?.stringValue
            )
        }

        guard let geometriesRoot = (try? document.nodes(forXPath: "//Geometries"))?.first as? XMLElement else { return nil }

        func parseNode(_ element: XMLElement) -> GDTFGeometryNode {
            var children: [GDTFGeometryNode] = []
            for case let child as XMLElement in element.children ?? [] {
                children.append(parseNode(child))
            }
            return GDTFGeometryNode(
                modelName: element.attribute(forName: "Model")?.stringValue,
                localOffset: parseTranslation(element.attribute(forName: "Position")?.stringValue),
                children: children
            )
        }

        let roots = ((geometriesRoot.children ?? []).compactMap { $0 as? XMLElement }).map(parseNode)
        guard !roots.isEmpty else { return nil }

        var meshes: [String: GDTF3DSParser.RawMesh] = [:]
        for info in models.values {
            guard let file = info.meshFileName, meshes[file] == nil else { continue }
            let candidatePath = "models/3ds/\(file).3ds"
            guard let entry = archive.first(where: { $0.path.lowercased() == candidatePath.lowercased() }) else { continue }
            var meshData = Data()
            _ = try? archive.extract(entry) { meshData.append($0) }
            if let mesh = GDTF3DSParser.parse(meshData) {
                meshes[file] = mesh
            }
        }

        return GDTFAssembly(roots: roots, models: models, meshes: meshes)
    }

    /// A GDTF `Position` matrix is a row-major 4x4 (16 numbers): each of
    /// the first 3 rows is [axis-x, axis-y, axis-z, translation]. The
    /// translation is therefore the 4th number of each of those rows —
    /// indices 3, 7, 11 — not the trailing homogeneous row (12...15, which
    /// is always [0,0,0,1]). Remapped from GDTF axes (X right, Y depth,
    /// Z up) into this app's scene axes (Y up) the same way fixture
    /// positions are elsewhere.
    private static func parseTranslation(_ text: String?) -> SCNVector3 {
        guard let text else { return SCNVector3Zero }
        let cleaned = text
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        let numbers = cleaned.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 12 else { return SCNVector3Zero }
        return SCNVector3(CGFloat(numbers[3]), CGFloat(numbers[11]), CGFloat(-numbers[7]))
    }
}

extension GDTFGeometryNode {
    /// Recursively builds the SCNNode tree for this geometry node and its
    /// children. A node only gets visible geometry when its Model has a
    /// parseable .3ds mesh; otherwise it falls back to a plain box sized
    /// from the Model's declared dimensions (still useful for silhouette),
    /// or contributes no geometry at all (a pure pivot, e.g. many Beam
    /// nodes) if neither is available.
    func buildNode(models: [String: GDTFModelInfo], meshes: [String: GDTF3DSParser.RawMesh]) -> SCNNode {
        let node = SCNNode()
        node.position = localOffset

        // "Dummy" models are placeholder/helper geometry (e.g. individual
        // pixel markers along a bar — a single fixture can reference dozens
        // of these), not part of the physical silhouette worth rendering.
        let isDummy = modelName?.lowercased().contains("dummy") ?? false

        if let modelName, !isDummy, let info = models[modelName] {
            let material = SCNMaterial()
            material.isDoubleSided = true
            material.diffuse.contents = NSColor(calibratedWhite: 0.75, alpha: 1)

            if let file = info.meshFileName,
               let mesh = meshes[file],
               let geometry = mesh.buildGeometry(width: info.width, length: info.length, height: info.height) {
                geometry.materials = [material]
                node.geometry = geometry
            } else if info.width > 0, info.height > 0, info.length > 0 {
                let box = SCNBox(width: CGFloat(info.width), height: CGFloat(info.height), length: CGFloat(info.length), chamferRadius: 0)
                box.materials = [material]
                node.geometry = box
            }
        }

        for child in children {
            node.addChildNode(child.buildNode(models: models, meshes: meshes))
        }
        return node
    }
}
