import Foundation
import SceneKit
import AppKit
import ZIPFoundation
import CryptoKit

// MARK: - glTF binary (.glb)

/// Minimal glTF 2.0 binary reader for MVR scene geometry. Only the subset
/// MVR exporters actually emit is handled — indexed triangle meshes with
/// float POSITION/NORMAL — which was verified against every .glb in the
/// sample files (all mode 4, all indexed, no sparse accessors).
///
/// Unlike GDTF's `.3ds` models, glb geometry is already in metres with Y
/// up, i.e. the same convention as this app's SceneKit scene, so its
/// vertices are used as-is with no unit or axis conversion.
enum GLBParser {
    private static let jsonChunk: UInt32 = 0x4E4F534A  // 'JSON'
    private static let binChunk: UInt32 = 0x004E4942   // 'BIN\0'

    /// componentType values from the glTF spec.
    private enum ComponentType: Int {
        case unsignedShort = 5123
        case unsignedInt = 5125
        case float = 5126
    }

    static func parse(_ data: Data) -> SCNNode? {
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { return nil }

        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        guard uint32(0) == 0x46546C67 else { return nil }  // 'glTF'

        var json: [String: Any]?
        var binary: [UInt8]?
        var offset = 12
        while offset + 8 <= bytes.count {
            let length = Int(uint32(offset))
            let type = uint32(offset + 4)
            let start = offset + 8
            guard length >= 0, start + length <= bytes.count else { break }
            if type == jsonChunk {
                json = (try? JSONSerialization.jsonObject(with: Data(bytes[start..<start + length]))) as? [String: Any]
            } else if type == binChunk {
                binary = Array(bytes[start..<start + length])
            }
            offset = start + length
        }

        guard let json, let binary else { return nil }

        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let bufferViews = json["bufferViews"] as? [[String: Any]] ?? []
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        let nodes = json["nodes"] as? [[String: Any]] ?? []

        /// Reads accessor `index` as a flat array of Floats (for vertex
        /// attributes) — component count per element is implied by `type`.
        func floats(accessor index: Int) -> [Float]? {
            guard index >= 0, index < accessors.count else { return nil }
            let accessor = accessors[index]
            guard
                let viewIndex = accessor["bufferView"] as? Int, viewIndex < bufferViews.count,
                let count = accessor["count"] as? Int,
                let rawComponent = accessor["componentType"] as? Int,
                ComponentType(rawValue: rawComponent) == .float,
                let type = accessor["type"] as? String
            else { return nil }

            let componentsPerElement: Int
            switch type {
            case "SCALAR": componentsPerElement = 1
            case "VEC2": componentsPerElement = 2
            case "VEC3": componentsPerElement = 3
            case "VEC4": componentsPerElement = 4
            default: return nil
            }

            let view = bufferViews[viewIndex]
            let viewOffset = (view["byteOffset"] as? Int) ?? 0
            let accessorOffset = (accessor["byteOffset"] as? Int) ?? 0
            let elementSize = componentsPerElement * 4
            let stride = (view["byteStride"] as? Int) ?? elementSize
            var result: [Float] = []
            result.reserveCapacity(count * componentsPerElement)

            for element in 0..<count {
                let base = viewOffset + accessorOffset + element * stride
                guard base + elementSize <= binary.count else { return nil }
                for component in 0..<componentsPerElement {
                    let p = base + component * 4
                    let bits = UInt32(binary[p]) | (UInt32(binary[p + 1]) << 8)
                        | (UInt32(binary[p + 2]) << 16) | (UInt32(binary[p + 3]) << 24)
                    result.append(Float(bitPattern: bits))
                }
            }
            return result
        }

        /// Reads an index accessor (unsigned short or int) as Int32s.
        func indices(accessor index: Int) -> [Int32]? {
            guard index >= 0, index < accessors.count else { return nil }
            let accessor = accessors[index]
            guard
                let viewIndex = accessor["bufferView"] as? Int, viewIndex < bufferViews.count,
                let count = accessor["count"] as? Int,
                let rawComponent = accessor["componentType"] as? Int,
                let component = ComponentType(rawValue: rawComponent)
            else { return nil }

            let view = bufferViews[viewIndex]
            let base = ((view["byteOffset"] as? Int) ?? 0) + ((accessor["byteOffset"] as? Int) ?? 0)
            var result: [Int32] = []
            result.reserveCapacity(count)

            switch component {
            case .unsignedShort:
                for i in 0..<count {
                    let p = base + i * 2
                    guard p + 2 <= binary.count else { return nil }
                    result.append(Int32(UInt32(binary[p]) | (UInt32(binary[p + 1]) << 8)))
                }
            case .unsignedInt:
                for i in 0..<count {
                    let p = base + i * 4
                    guard p + 4 <= binary.count else { return nil }
                    let value = UInt32(binary[p]) | (UInt32(binary[p + 1]) << 8)
                        | (UInt32(binary[p + 2]) << 16) | (UInt32(binary[p + 3]) << 24)
                    result.append(Int32(truncatingIfNeeded: value))
                }
            case .float:
                return nil
            }
            return result
        }

        func geometryNode(meshIndex: Int) -> SCNNode? {
            guard meshIndex >= 0, meshIndex < meshes.count else { return nil }
            let primitives = meshes[meshIndex]["primitives"] as? [[String: Any]] ?? []
            let container = SCNNode()

            for primitive in primitives {
                // mode 4 == TRIANGLES; anything else (lines/points/strips)
                // isn't meaningful for a solid-set preview.
                let mode = (primitive["mode"] as? Int) ?? 4
                guard mode == 4 else { continue }
                guard
                    let attributes = primitive["attributes"] as? [String: Any],
                    let positionIndex = attributes["POSITION"] as? Int,
                    let positions = floats(accessor: positionIndex),
                    positions.count >= 9
                else { continue }

                var vertices: [SCNVector3] = []
                vertices.reserveCapacity(positions.count / 3)
                for i in stride(from: 0, to: positions.count - 2, by: 3) {
                    vertices.append(SCNVector3(CGFloat(positions[i]), CGFloat(positions[i + 1]), CGFloat(positions[i + 2])))
                }

                let triangleIndices: [Int32]
                if let indexAccessor = primitive["indices"] as? Int, let parsed = indices(accessor: indexAccessor) {
                    triangleIndices = parsed
                } else {
                    triangleIndices = (0..<Int32(vertices.count)).map { $0 }
                }
                guard triangleIndices.count >= 3 else { continue }

                var sources = [SCNGeometrySource(vertices: vertices)]
                if let normalIndex = attributes["NORMAL"] as? Int,
                   let rawNormals = floats(accessor: normalIndex),
                   rawNormals.count == positions.count {
                    var normals: [SCNVector3] = []
                    normals.reserveCapacity(rawNormals.count / 3)
                    for i in stride(from: 0, to: rawNormals.count - 2, by: 3) {
                        normals.append(SCNVector3(CGFloat(rawNormals[i]), CGFloat(rawNormals[i + 1]), CGFloat(rawNormals[i + 2])))
                    }
                    sources.append(SCNGeometrySource(normals: normals))
                }

                let element = SCNGeometryElement(indices: triangleIndices, primitiveType: .triangles)
                let geometry = SCNGeometry(sources: sources, elements: [element])
                geometry.materials = [MVRSceneGeometryLoader.makeSceneMaterial()]
                container.addChildNode(SCNNode(geometry: geometry))
            }

            return container.childNodes.isEmpty ? nil : container
        }

        let root = SCNNode()
        for node in nodes {
            guard let meshIndex = node["mesh"] as? Int, let built = geometryNode(meshIndex: meshIndex) else { continue }
            if let matrix = node["matrix"] as? [Double], matrix.count == 16 {
                // glTF stores column-major and applies M*v; SCNMatrix4 is
                // row-vector with translation in m41…m43, so filling the
                // fields in order transposes it, which is exactly right.
                let m = matrix.map { CGFloat($0) }
                built.transform = SCNMatrix4(
                    m11: m[0], m12: m[1], m13: m[2], m14: m[3],
                    m21: m[4], m22: m[5], m23: m[6], m24: m[7],
                    m31: m[8], m32: m[9], m33: m[10], m34: m[11],
                    m41: m[12], m42: m[13], m43: m[14], m44: m[15])
            }
            root.addChildNode(built)
        }
        return root.childNodes.isEmpty ? nil : root
    }
}

// MARK: - Where geometry comes from

/// An MVR's scene geometry as a document currently has it: the file, the
/// scene description if it has been edited since, and any mesh files
/// rewritten here. Plain data, so a background load can take it.
nonisolated struct MVRGeometrySource: Sendable {
    let url: URL
    /// The edited scene description, or nil to read the file's own.
    let sceneXML: Data?
    /// Rewritten mesh files by lowercased file name, read instead of the
    /// archive's copies.
    let meshOverrides: [String: Data]

    func readSceneDescription() -> XMLDocument? {
        if let sceneXML { return try? XMLDocument(data: sceneXML, options: []) }
        guard
            let archive = try? Archive(url: url, accessMode: .read),
            let entry = archive["GeneralSceneDescription.xml"]
        else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return try? XMLDocument(data: data, options: [])
    }
}

// MARK: - Scene geometry loader

/// Builds the SceneKit node tree for an MVR's non-fixture geometry — set,
/// video walls, staging, trusses and so on.
///
/// The MVR structure is `<SceneObject><Geometries><Symbol symdef=…>`, where
/// the symdef resolves against `<AUXData><Symdef uuid=…>` and that in turn
/// holds `<Geometry3D fileName=…>` entries (and possibly further nested
/// `<Symbol>` references). Symdefs are heavily shared — one sample file has
/// 5991 scene objects drawn from only 59 symdefs — so each symdef is built
/// once into a template and cloned per use.
enum MVRSceneGeometryLoader {

    /// One MVR layer's worth of scene geometry. The matching child node
    /// under the geometry root is named with `uuid`, so the scene explorer
    /// can show and hide a layer without re-walking the XML.
    struct SceneGeometryLayer: Sendable {
        let uuid: String
        let name: String
        let objectCount: Int
    }

    /// One selectable scene object. `id` is also the name of the matching
    /// node in the geometry tree, so a hit-test result can be traced back
    /// to the object it belongs to by walking up to the nearest ancestor
    /// carrying an id with this prefix.
    struct SceneGeometryObject: Sendable {
        static let nodeNamePrefix = "sceneObject:"

        let id: String
        let name: String
        let layerUUID: String
        /// The object's key, as `objectKeys(_:)` gives it, so a click in a
        /// view built from this can be traced back to the object in the
        /// file. Nil for a layer merged into one node, which is many.
        var key: String? = nil
    }

    /// Lets a finished node tree cross back from the loading task. SCNNode
    /// isn't Sendable, but the tree is built entirely inside that task and
    /// isn't touched again until it's handed over, so the transfer is safe.
    struct LoadedGeometry: @unchecked Sendable {
        let node: SCNNode?
        let layers: [SceneGeometryLayer]
        let objects: [SceneGeometryObject]
    }

    /// Resting colour of scene geometry. Exposed so the export-selection
    /// tint can restore it exactly on deselect.
    nonisolated static let baseColor = NSColor(calibratedWhite: 0.62, alpha: 1)

    /// Colour marking geometry as selected for export.
    nonisolated static let selectedColor = NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.96, alpha: 1)

    nonisolated static func makeSceneMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = baseColor
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.85
        material.metalness.contents = 0.0
        // Set geometry is frequently modelled as open shells with
        // inconsistent winding; without this, faces disappear when viewed
        // from the "wrong" side.
        material.isDoubleSided = true
        return material
    }

    /// MVR world (X right, Y depth, Z up, millimetres) → scene (Y up,
    /// metres). Fixture positions use the same remap.
    private static let mvrToScene = SCNMatrix4MakeRotation(-.pi / 2, 1, 0, 0)

    /// Builds the geometry node for the MVR at `url`, or nil if it has
    /// none. Real files can hold thousands of meshes, which is far too slow
    /// to do on the main thread, so this takes only a plain file URL and
    /// re-reads the scene description itself — that keeps it free of any
    /// main-actor state and safe to run on a background task.
    nonisolated static func buildGeometryNode(mvrURL url: URL) -> LoadedGeometry {
        buildNode(source: MVRGeometrySource(url: url, sceneXML: nil, meshOverrides: [:]))
    }

    /// The same, for a document whose geometry may have been edited.
    nonisolated static func buildGeometryNode(source: MVRGeometrySource) -> LoadedGeometry {
        buildNode(source: source)
    }

    /// A mesh parsed into plain arrays, already in scene space (metres, Y
    /// up). Kept as arrays rather than an `SCNGeometry` so many of them can
    /// be concatenated into one merged buffer (see `mergedNodes`) with no
    /// intermediate SceneKit objects, and so parsing can run on several
    /// threads at once.
    private struct RawSceneMesh {
        let positions: [SCNVector3]
        /// Only present when the source file supplied normals (`.glb` does,
        /// `.3ds` doesn't), so merging never invents shading that wasn't
        /// there before.
        let normals: [SCNVector3]?
        let indices: [Int32]
    }

    /// One placement of a cached mesh within a scene object's own space.
    /// These come from the XML alone, before any mesh file is read, which is
    /// what lets the whole mesh set be parsed in parallel afterwards.
    private struct MeshPlacement {
        let meshKey: String
        let transform: SCNMatrix4
    }

    /// Resolves `<Geometry3D>` and `<Symbol>` references into mesh
    /// placements, caching each symdef's own placements so one used many
    /// times is only walked once. Shared by the whole-scene build and the
    /// Geometry Inspector's one-symbol-at-a-time build.
    private nonisolated final class PlacementResolver {
        /// Every symdef by lowercased uuid, so `<Symbol symdef="…">` can
        /// resolve.
        let symdefElements: [String: XMLElement]
        private var symdefPlacements: [String: [MeshPlacement]] = [:]

        init(xmlDocument: XMLDocument) {
            var elements: [String: XMLElement] = [:]
            for case let element as XMLElement in (try? xmlDocument.nodes(forXPath: "//Symdef")) ?? [] {
                if let uuid = element.attribute(forName: "uuid")?.stringValue?.lowercased() {
                    elements[uuid] = element
                }
            }
            symdefElements = elements
        }

        /// Collects (or returns cached) placements for one symdef, in the
        /// symdef's own space. `stack` guards against a symdef that
        /// transitively references itself, which would otherwise recurse
        /// forever.
        func placements(forSymdef uuid: String, stack: Set<String>) -> [MeshPlacement] {
            let key = uuid.lowercased()
            if let cached = symdefPlacements[key] { return cached }
            guard !stack.contains(key), let element = symdefElements[key] else { return [] }

            var result: [MeshPlacement] = []
            collectPlacements(of: element, accumulated: SCNMatrix4Identity, into: &result, stack: stack.union([key]))
            symdefPlacements[key] = result
            return result
        }

        /// Walks an element's descendants for the two things that produce
        /// geometry — direct `<Geometry3D>` file references and `<Symbol>`
        /// symdef instances — recording each as a placement with its
        /// transform composed all the way down. A symdef's placements are
        /// worked out once and re-composed per instance, so a symdef used
        /// many times is still only walked once.
        func collectPlacements(
            of element: XMLElement,
            accumulated: SCNMatrix4,
            into out: inout [MeshPlacement],
            stack: Set<String>
        ) {
            for case let child as XMLElement in element.children ?? [] {
                switch child.name {
                case "Geometry3D":
                    guard let fileName = child.attribute(forName: "fileName")?.stringValue else { continue }
                    let local = transform(from: child) ?? SCNMatrix4Identity
                    out.append(MeshPlacement(
                        meshKey: fileName.lowercased(),
                        transform: SCNMatrix4Mult(local, accumulated)))

                case "Symbol":
                    guard let symdefUUID = child.attribute(forName: "symdef")?.stringValue else { continue }
                    let local = transform(from: child) ?? SCNMatrix4Identity
                    let composed = SCNMatrix4Mult(local, accumulated)
                    for placement in placements(forSymdef: symdefUUID, stack: stack) {
                        out.append(MeshPlacement(
                            meshKey: placement.meshKey,
                            transform: SCNMatrix4Mult(placement.transform, composed)))
                    }

                default:
                    // Containers such as <ChildList> and <Geometries> just
                    // nest the elements above.
                    collectPlacements(of: child, accumulated: accumulated, into: &out, stack: stack)
                }
            }
        }
    }

    /// Vertex ceiling for one merged geometry. Merging is what makes a large
    /// file navigable — a CAD-exported venue arrives as tens of thousands of
    /// tiny separate meshes, and a draw call each is what makes it crawl —
    /// but merging *everything* into one geometry would equally defeat
    /// SceneKit's frustum culling, so the merge is chunked: few enough nodes
    /// to be cheap to draw, enough of them that off-screen parts can still
    /// be skipped.
    private static let maxVerticesPerMergedChunk = 120_000

    /// A layer with more objects than this, essentially all of them
    /// nameless, is merged into one selectable object instead of being kept
    /// object-by-object.
    ///
    /// Naming turns out to separate the two kinds of file cleanly. Measured
    /// across five real venue exports: a CAD explosion had **60,592 objects,
    /// 100% unnamed** (every tube and bolt of the staging emitted
    /// separately), while every hand-built show — 4,540, 2,565, 1,718 and
    /// 1,202 objects — was **0% unnamed**. So this only ever catches the
    /// case where per-object selection was worthless anyway, and leaves real
    /// shows selectable exactly as before.
    /// Every MVR object type that can carry its own `<Geometries>`, in
    /// document order. `<SceneObject>` alone missed most rigging: one real
    /// festival file has 7,692 `<Truss>`, 45 `<Support>` and 5
    /// `<VideoScreen>` objects against 709 scene objects. Across the local
    /// sample files none of these sits inside another, so no object's
    /// meshes get collected twice.
    nonisolated static let geometryObjectsXPath =
        "//SceneObject | //Truss | //Support | //VideoScreen | //Projector | //FocusPoint"

    /// What identifies each object across edits: its uuid, lowercased —
    /// every object in every real file checked has one, all unique — or,
    /// failing that, its place in the file.
    nonisolated static func objectKeys(_ elements: [XMLElement]) -> [String] {
        let uuids = elements.map { $0.attribute(forName: "uuid")?.stringValue?.lowercased() ?? "" }
        var counts: [String: Int] = [:]
        for uuid in uuids where !uuid.isEmpty { counts[uuid, default: 0] += 1 }
        return uuids.enumerated().map { index, uuid in
            !uuid.isEmpty && counts[uuid] == 1 ? uuid : "#\(index)"
        }
    }

    /// An MVR `<Matrix>`'s translation, in millimetres; nil without one.
    nonisolated static func translation(ofMatrixText text: String) -> SIMD3<Double>? {
        let values = numbers(in: text).map(Double.init)
        guard values.count >= 12 else { return nil }
        return SIMD3(values[9], values[10], values[11])
    }

    /// `text` with its translation replaced, keeping the rotation; an
    /// identity rotation when there's no matrix to keep.
    nonisolated static func matrixText(_ text: String?, movedTo position: SIMD3<Double>) -> String {
        var values = numbers(in: text ?? "").map(Double.init)
        if values.count < 12 { values = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0] }
        values[9] = position.x; values[10] = position.y; values[11] = position.z
        func group(_ range: Range<Int>) -> String {
            "{" + values[range].map { String(format: "%.6f", $0) }.joined(separator: ",") + "}"
        }
        return group(0..<3) + group(3..<6) + group(6..<9) + group(9..<12)
    }

    /// The element names in `geometryObjectsXPath`.
    nonisolated static let geometryObjectTags: Set<String> = [
        "SceneObject", "Truss", "Support", "VideoScreen", "Projector", "FocusPoint",
    ]

    private static let bulkLayerMinimumObjects = 500
    private static let bulkLayerUnnamedFraction = 0.9

    private nonisolated static func buildNode(source: MVRGeometrySource) -> LoadedGeometry {
        let empty = LoadedGeometry(node: nil, layers: [], objects: [])
        guard let xmlDocument = source.readSceneDescription() else { return empty }

        let resolver = PlacementResolver(xmlDocument: xmlDocument)

        // Pass 1: read the structure. No mesh file is touched yet, so this is
        // pure XML work, and it establishes exactly which meshes are actually
        // referenced — anything unreferenced never gets parsed at all.
        var pendingObjects: [(element: XMLElement, placements: [MeshPlacement])] = []
        var usedMeshKeys: Set<String> = []
        let objectElements = ((try? xmlDocument.nodes(forXPath: geometryObjectsXPath)) ?? [])
            .compactMap { $0 as? XMLElement }
        var keyOfElement: [ObjectIdentifier: String] = [:]
        for (element, key) in zip(objectElements, objectKeys(objectElements)) {
            keyOfElement[ObjectIdentifier(element)] = key
        }
        for sceneObject in objectElements {
            var objectPlacements: [MeshPlacement] = []
            resolver.collectPlacements(of: sceneObject, accumulated: SCNMatrix4Identity, into: &objectPlacements, stack: [])
            guard !objectPlacements.isEmpty else { continue }
            for placement in objectPlacements { usedMeshKeys.insert(placement.meshKey) }
            pendingObjects.append((sceneObject, objectPlacements))
        }
        guard !pendingObjects.isEmpty else { return empty }

        // Pass 2: unzip and parse the mesh files. This dominates load time on
        // a big file — one real venue export references 19,508 distinct
        // meshes — and each file is independent, so it's spread over the
        // cores.
        let meshes = parseMeshes(keys: Array(usedMeshKeys), source: source)

        // Pass 3: build the node tree from the parsed meshes.
        let root = SCNNode()
        root.name = "sceneGeometry"

        // Scene objects are grouped under one node per MVR layer so the
        // scene explorer can toggle a layer's set geometry the same way it
        // toggles that layer's fixtures.
        var layerNodes: [String: SCNNode] = [:]
        var layerNames: [String: String] = [:]
        var layerCounts: [String: Int] = [:]
        var layerOrder: [String] = []
        var objects: [SceneGeometryObject] = []

        // Merging inside a scene object only pays off when objects hold many
        // meshes. Some exporters do the opposite and emit one object *per
        // mesh* — one real file has 60,592 objects of exactly one mesh each,
        // where per-object merging can do nothing at all and every object
        // stays its own draw call. Those layers are merged wholesale
        // instead: at that count the objects are unnamed CAD fragments
        // (every tube and bolt of the staging), so treating a layer as one
        // selectable thing loses nothing anybody could use.
        var objectsPerLayer: [String: Int] = [:]
        var unnamedPerLayer: [String: Int] = [:]
        for (sceneObject, _) in pendingObjects {
            let key = owningLayer(of: sceneObject).uuid.lowercased()
            objectsPerLayer[key, default: 0] += 1
            let name = sceneObject.attribute(forName: "name")?.stringValue ?? ""
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                unnamedPerLayer[key, default: 0] += 1
            }
        }
        let bulkLayers = Set(objectsPerLayer.filter { key, count in
            count > bulkLayerMinimumObjects
                && Double(unnamedPerLayer[key] ?? 0) / Double(count) >= bulkLayerUnnamedFraction
        }.keys)

        if !bulkLayers.isEmpty {
            var placementsByLayer: [String: [MeshPlacement]] = [:]
            var namesByLayer: [String: String] = [:]
            var order: [String] = []

            for (sceneObject, objectPlacements) in pendingObjects {
                let layer = owningLayer(of: sceneObject)
                let key = layer.uuid.lowercased()
                guard bulkLayers.contains(key) else { continue }

                // Each object carries its own placement, so merging across
                // them means folding that in before the meshes are combined.
                let objectMatrix = transform(from: sceneObject) ?? SCNMatrix4Identity
                if placementsByLayer[key] == nil {
                    placementsByLayer[key] = []
                    namesByLayer[key] = layer.name
                    order.append(key)
                }
                placementsByLayer[key]?.append(contentsOf: objectPlacements.map {
                    MeshPlacement(meshKey: $0.meshKey, transform: SCNMatrix4Mult($0.transform, objectMatrix))
                })
            }

            for key in order {
                let chunks = mergedNodes(placements: placementsByLayer[key] ?? [], meshes: meshes)
                guard !chunks.isEmpty else { continue }

                let node = SCNNode()
                for chunk in chunks { node.addChildNode(chunk) }

                let objectID = "\(SceneGeometryObject.nodeNamePrefix)\(objects.count)"
                node.name = objectID
                objects.append(SceneGeometryObject(
                    id: objectID,
                    name: "\(namesByLayer[key] ?? "Layer") (\(objectsPerLayer[key] ?? 0) parts, merged)",
                    layerUUID: key))

                let layerNode = SCNNode()
                layerNode.name = key
                layerNodes[key] = layerNode
                layerOrder.append(key)
                layerNames[key] = namesByLayer[key] ?? ""
                root.addChildNode(layerNode)
                layerNode.addChildNode(node)
                layerCounts[key, default: 0] += 1
            }
        }

        for (sceneObject, objectPlacements) in pendingObjects {
            let layer = owningLayer(of: sceneObject)
            let key = layer.uuid.lowercased()
            guard !bulkLayers.contains(key) else { continue }

            let chunks = mergedNodes(placements: objectPlacements, meshes: meshes)
            guard !chunks.isEmpty else { continue }

            let node = SCNNode()
            if let matrix = transform(from: sceneObject) {
                node.transform = matrix
            }
            for chunk in chunks { node.addChildNode(chunk) }

            // Index-based rather than the SceneObject's own uuid: the uuid
            // is optional and not guaranteed unique across a file, and this
            // id only has to be stable for the lifetime of one load.
            let objectID = "\(SceneGeometryObject.nodeNamePrefix)\(objects.count)"
            node.name = objectID
            objects.append(SceneGeometryObject(
                id: objectID,
                name: sceneObject.attribute(forName: "name")?.stringValue ?? "Object",
                layerUUID: key,
                key: keyOfElement[ObjectIdentifier(sceneObject)]))
            if layerNodes[key] == nil {
                let layerNode = SCNNode()
                layerNode.name = key
                layerNodes[key] = layerNode
                layerNames[key] = layer.name
                layerOrder.append(key)
                root.addChildNode(layerNode)
            }
            layerNodes[key]?.addChildNode(node)
            layerCounts[key, default: 0] += 1
        }

        guard !root.childNodes.isEmpty else { return empty }

        // Set geometry runs to thousands of meshes; making all of it cast
        // shadows roughly doubles the per-frame cost for no real benefit in
        // a plot-checking tool, where the fixtures are what matter.
        root.enumerateHierarchy { node, _ in node.castsShadow = false }

        let layers = layerOrder.map {
            SceneGeometryLayer(uuid: $0, name: layerNames[$0] ?? "", objectCount: layerCounts[$0] ?? 0)
        }
        return LoadedGeometry(node: root, layers: layers, objects: objects)
    }

    // MARK: - Mesh parsing

    /// Unzips and parses every referenced mesh, in parallel.
    ///
    /// Two things matter for speed here, and they interact:
    ///
    /// The name→entry index is built **once** and shared. Scanning the
    /// archive per lookup instead is quadratic — on one real file that alone
    /// took over a minute — but building the index is itself not free
    /// (0.25s for 19,769 entries), so having each worker build its own
    /// exactly cancelled out the gain from parallelising: measured on the
    /// same file, per-worker indexes ran 1.31s against 1.34s serial, while
    /// sharing one index brought it to 0.82s.
    ///
    /// Sharing is sound because `Entry` is a pure value describing where the
    /// bytes live (offsets, sizes, names) and holds no reference back to the
    /// `Archive` it came from, so entries indexed through one handle extract
    /// correctly through another on the same file. Each worker still needs
    /// its own `Archive`, since a handle can't be read from concurrently.
    private nonisolated static func parseMeshes(keys: [String], source: MVRGeometrySource) -> [String: RawSceneMesh] {
        guard !keys.isEmpty else { return [:] }
        guard let entriesByName = archiveIndex(mvrURL: source.url) else { return [:] }
        return parseMeshes(keys: keys, mvrURL: source.url, index: entriesByName, overrides: source.meshOverrides)
    }

    /// Every archive entry by lowercased file name.
    private nonisolated static func archiveIndex(mvrURL url: URL) -> [String: Entry]? {
        guard let indexArchive = try? Archive(url: url, accessMode: .read) else { return nil }
        var entriesByName: [String: Entry] = [:]
        for entry in indexArchive {
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            if entriesByName[name] == nil { entriesByName[name] = entry }
        }
        return entriesByName
    }

    private nonisolated static func parseMeshes(
        keys: [String], mvrURL url: URL, index entriesByName: [String: Entry],
        overrides: [String: Data] = [:]
    ) -> [String: RawSceneMesh] {
        guard !keys.isEmpty else { return [:] }
        // Read-only from every worker once built.
        nonisolated(unsafe) let sharedIndex = entriesByName

        let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
        var parsed = [RawSceneMesh?](repeating: nil, count: keys.count)

        parsed.withUnsafeMutableBufferPointer { buffer in
            // Each iteration only ever touches indices no other iteration
            // touches, so the writes don't overlap.
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                guard let archive = try? Archive(url: url, accessMode: .read) else { return }

                // Strided rather than split into contiguous blocks, so one
                // worker landing on a run of unusually large meshes doesn't
                // hold everything else up.
                var index = worker
                while index < keys.count {
                    let key = keys[index]
                    if let replaced = overrides[key] {
                        slots[index] = rawMesh(from: replaced, key: key)
                    } else if let entry = sharedIndex[key] {
                        var data = Data()
                        _ = try? archive.extract(entry) { data.append($0) }
                        if !data.isEmpty {
                            slots[index] = rawMesh(from: data, key: key)
                        }
                    }
                    index += workerCount
                }
            }
        }

        var result: [String: RawSceneMesh] = [:]
        result.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() where parsed[index] != nil {
            result[key] = parsed[index]
        }
        return result
    }

    private nonisolated static func rawMesh(from data: Data, key: String) -> RawSceneMesh? {
        if key.hasSuffix(".glb") || key.hasSuffix(".gltf") {
            guard let node = GLBParser.parse(data) else { return nil }
            return rawMesh(fromParsed: node)
        }
        guard key.hasSuffix(".3ds"), let mesh = GDTF3DSParser.parse(data) else { return nil }
        guard mesh.vertices.count >= 3, mesh.faceIndices.count >= 3 else { return nil }

        // Unlike GDTF's unit-normalised fixture models, scene `.3ds` meshes
        // carry real-world coordinates in millimetres in the MVR's own Z-up
        // frame, so they're converted to this app's scene convention
        // (metres, Y up) with the same remap used for fixture positions.
        let positions = mesh.vertices.map { SCNVector3($0.x / 1000, $0.z / 1000, -$0.y / 1000) }
        // Once merged, an out-of-range index would silently point into some
        // other mesh's vertices rather than producing a local artefact, so a
        // bad mesh is dropped instead of concatenated.
        guard mesh.faceIndices.allSatisfy({ $0 >= 0 && Int($0) < positions.count }) else { return nil }
        return RawSceneMesh(positions: positions, normals: nil, indices: mesh.faceIndices)
    }

    /// Flattens a `.glb`'s parsed node tree back into plain arrays so it can
    /// take part in the same merge as `.3ds` meshes.
    private nonisolated static func rawMesh(fromParsed root: SCNNode) -> RawSceneMesh? {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        var hasNormals = true

        root.enumerateHierarchy { node, _ in
            guard
                let geometry = node.geometry,
                let positionSource = geometry.sources(for: .vertex).first
            else { return }
            let points = SCNGeometryMerge.readVectors(positionSource)
            guard !points.isEmpty else { return }

            // The tree is freshly parsed and unattached, so worldTransform is
            // exactly the placement relative to `root`.
            let placement = node.worldTransform
            let base = Int32(positions.count)

            var meshIndices: [Int32] = []
            for element in geometry.elements where element.primitiveType == .triangles {
                let read = SCNGeometryMerge.readIndices(element)
                guard read.allSatisfy({ $0 >= 0 && $0 < points.count }) else { continue }
                meshIndices.append(contentsOf: read.map { base + Int32($0) })
            }
            guard !meshIndices.isEmpty else { return }

            for point in points { positions.append(SCNGeometryMerge.transformPoint(point, placement)) }
            let sourceNormals = geometry.sources(for: .normal).first.map(SCNGeometryMerge.readVectors) ?? []
            if hasNormals, sourceNormals.count == points.count {
                for normal in sourceNormals {
                    normals.append(SCNGeometryMerge.normalize(SCNGeometryMerge.transformDirection(normal, placement)))
                }
            } else {
                hasNormals = false
            }
            indices.append(contentsOf: meshIndices)
        }

        guard positions.count >= 3, indices.count >= 3 else { return nil }
        return RawSceneMesh(
            positions: positions,
            normals: (hasNormals && normals.count == positions.count) ? normals : nil,
            indices: indices)
    }

    // MARK: - Mesh merging

    /// Concatenates a scene object's mesh placements into as few geometries
    /// as the chunk ceiling allows, baking each placement's transform into
    /// the vertices.
    ///
    /// The merged geometry stays *inside* the object's own node, so
    /// everything keyed off per-object nodes keeps working untouched:
    /// hit-testing walks up to the owning `sceneObject:` ancestor,
    /// export-selection tinting and OBJ export both walk the object's
    /// hierarchy, and layer visibility sits a level above.
    private nonisolated static func mergedNodes(
        placements: [MeshPlacement],
        meshes: [String: RawSceneMesh]
    ) -> [SCNNode] {
        var nodes: [SCNNode] = []
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        var chunkHasNormals = true

        func flush() {
            defer {
                positions.removeAll(keepingCapacity: true)
                normals.removeAll(keepingCapacity: true)
                indices.removeAll(keepingCapacity: true)
                chunkHasNormals = true
            }
            guard positions.count >= 3, indices.count >= 3 else { return }

            var sources = [SCNGeometrySource(vertices: positions)]
            if chunkHasNormals, normals.count == positions.count {
                sources.append(SCNGeometrySource(normals: normals))
            }
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: sources, elements: [element])
            geometry.materials = [makeSceneMaterial()]
            nodes.append(SCNNode(geometry: geometry))
        }

        for placement in placements {
            guard let mesh = meshes[placement.meshKey] else { continue }
            if !positions.isEmpty,
               positions.count + mesh.positions.count > maxVerticesPerMergedChunk {
                flush()
            }

            let base = Int32(positions.count)
            for point in mesh.positions {
                positions.append(SCNGeometryMerge.transformPoint(point, placement.transform))
            }
            if chunkHasNormals, let meshNormals = mesh.normals, meshNormals.count == mesh.positions.count {
                for normal in meshNormals {
                    normals.append(SCNGeometryMerge.normalize(SCNGeometryMerge.transformDirection(normal, placement.transform)))
                }
            } else {
                chunkHasNormals = false
            }
            for index in mesh.indices { indices.append(base + index) }
        }
        flush()

        return nodes
    }

    /// Finds the `<Layer>` a scene object sits in. MVR nests these as
    /// `Layer > ChildList > SceneObject`, but the depth isn't guaranteed,
    /// so this walks ancestors rather than assuming a fixed level.
    private nonisolated static func owningLayer(of element: XMLElement) -> (uuid: String, name: String) {
        var current = element.parent as? XMLElement
        while let node = current {
            if node.name == "Layer" {
                return (node.attribute(forName: "uuid")?.stringValue ?? "",
                        node.attribute(forName: "name")?.stringValue ?? "Unnamed layer")
            }
            current = node.parent as? XMLElement
        }
        return ("", "Ungrouped")
    }

    /// Converts an element's own `<Matrix>` into a scene-space transform.
    ///
    /// The MVR matrix is 12 numbers: three basis vectors then a translation,
    /// expressed in the MVR's millimetre Z-up frame. Since the geometry it
    /// transforms has already been converted into scene space, the matrix
    /// has to be expressed in that space too — hence conjugating by the
    /// axis remap (`R⁻¹ · B · R`) rather than just remapping the
    /// translation. Roughly a third of scene objects in real files carry a
    /// non-identity rotation, so this genuinely matters.
    /// The rotation an MVR `<Matrix>` describes, in scene space, with the
    /// translation left out.
    ///
    /// For fixtures, whose position is applied separately from the marker's
    /// own placement. The change of basis is the part that is easy to skip
    /// and impossible to eyeball: MVR is Z-up and the scene is Y-up, so a
    /// basis dropped in raw tips every fixture onto its side. Same triple
    /// product `transform(from:)` uses on scene objects.
    ///
    /// Nil when the matrix has no usable basis, which is the signal to
    /// leave the fixture unrotated rather than guess.
    nonisolated static func orientation(fromMatrixText text: String) -> SCNMatrix4? {
        let values = numbers(in: text)
        guard values.count >= 9 else { return nil }

        var basis = SCNMatrix4Identity
        basis.m11 = values[0]; basis.m12 = values[1]; basis.m13 = values[2]
        basis.m21 = values[3]; basis.m22 = values[4]; basis.m23 = values[5]
        basis.m31 = values[6]; basis.m32 = values[7]; basis.m33 = values[8]

        // An all-zero basis is a matrix that says nothing, not a fixture
        // squashed to a point.
        guard values.prefix(9).contains(where: { $0 != 0 }) else { return nil }

        let inverse = SCNMatrix4Invert(mvrToScene)
        return SCNMatrix4Mult(SCNMatrix4Mult(inverse, basis), mvrToScene)
    }

    private nonisolated static func numbers(in text: String) -> [CGFloat] {
        text.replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .compactMap { Double($0) }
            .map { CGFloat($0) }
    }

    private nonisolated static func transform(from element: XMLElement) -> SCNMatrix4? {
        guard let text = element.elements(forName: "Matrix").first?.stringValue else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        let values = cleaned.split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
        guard values.count >= 12 else { return nil }

        var basis = SCNMatrix4Identity
        basis.m11 = values[0]; basis.m12 = values[1]; basis.m13 = values[2]
        basis.m21 = values[3]; basis.m22 = values[4]; basis.m23 = values[5]
        basis.m31 = values[6]; basis.m32 = values[7]; basis.m33 = values[8]
        basis.m41 = values[9] / 1000; basis.m42 = values[10] / 1000; basis.m43 = values[11] / 1000

        let inverse = SCNMatrix4Invert(mvrToScene)
        return SCNMatrix4Mult(SCNMatrix4Mult(inverse, basis), mvrToScene)
    }
}

// MARK: - One symbol or object at a time

extension MVRSceneGeometryLoader {

    /// One symbol or object built on its own, for the Geometry Inspector.
    struct SymbolPreview: @unchecked Sendable {
        /// Its meshes, in its own space (metres, Y up).
        let node: SCNNode
        let boundingBox: (min: SCNVector3, max: SCNVector3)
        let triangleCount: Int
        /// Meshes it places, nesting included.
        let meshPlacementCount: Int
        /// Placed meshes whose file is missing from the archive or
        /// couldn't be read.
        let missingMeshCount: Int
    }

    /// What the inspector's "Select Same…" matches objects on.
    struct ObjectTraits: Sendable {
        /// Equal for objects that draw the same thing: the same symbols,
        /// and own meshes with identical contents. Most "one-off" meshes
        /// aren't: one real file's 8,011 mesh files hold 293 distinct
        /// shapes. Nil for an object with no geometry.
        let model: String?
        /// Its materials' colours, as 0xRRGGBB.
        let colours: Set<UInt32>
    }

    /// What a simplify run produced.
    struct SimplifyResult: Sendable {
        /// Rewritten mesh files by lowercased file name; only the ones
        /// that actually got smaller.
        let files: [String: Data]
        let trianglesBefore: Int
        let trianglesAfter: Int
        /// Meshes looked at, rewritten or not.
        let meshCount: Int
    }

    /// A file's geometry, read once and then built a piece at a time as
    /// it's asked for. Parsed meshes are kept, so going back to something,
    /// or on to another piece sharing its meshes, doesn't unzip them again.
    actor SymbolLibrary {
        private let source: MVRGeometrySource
        private let xmlDocument: XMLDocument
        private let resolver: PlacementResolver
        private let index: [String: Entry]
        /// By `objectKeys(_:)`, as `GeometryInventory.objects` and the
        /// document's object edits identify them.
        private let objects: [String: XMLElement]
        private var meshes: [String: RawSceneMesh] = [:]
        private var unreadable: Set<String> = []

        /// Nil when the file can't be opened or has no scene description.
        init?(source: MVRGeometrySource) {
            guard
                let xmlDocument = source.readSceneDescription(),
                let index = MVRSceneGeometryLoader.archiveIndex(mvrURL: source.url)
            else { return nil }

            self.source = source
            self.xmlDocument = xmlDocument
            self.resolver = PlacementResolver(xmlDocument: xmlDocument)
            self.index = index
            let elements = ((try? xmlDocument.nodes(forXPath: MVRSceneGeometryLoader.geometryObjectsXPath)) ?? [])
                .compactMap { $0 as? XMLElement }
            self.elements = elements
            self.objects = Dictionary(
                zip(MVRSceneGeometryLoader.objectKeys(elements), elements),
                uniquingKeysWith: { first, _ in first })
        }

        /// In document order, for the inventory.
        private let elements: [XMLElement]

        init?(mvrURL url: URL) {
            self.init(source: MVRGeometrySource(url: url, sceneXML: nil, meshOverrides: [:]))
        }

        func inventory() -> GeometryInventory {
            GeometryInventory.read(xmlDocument, objects: elements)
        }

        /// Nil for a symbol with no readable meshes.
        func preview(symdef uuid: String) -> SymbolPreview? {
            preview(of: resolver.placements(forSymdef: uuid, stack: []))
        }

        /// An object's geometry in its own space, leaving out where it's
        /// placed. Nil when it has none that can be read.
        func preview(object key: String) -> SymbolPreview? {
            preview(of: placements(ofObject: key))
        }

        /// Objects where they stand in the scene, all in one, for drawing
        /// over the whole-scene view to pick them out.
        func highlight(objects keys: Set<String>) -> SymbolPreview? {
            var placements: [MeshPlacement] = []
            for key in keys {
                guard let element = objects[key] else { continue }
                let placed = MVRSceneGeometryLoader.transform(from: element) ?? SCNMatrix4Identity
                placements += placementsOf(element).map {
                    MeshPlacement(meshKey: $0.meshKey, transform: SCNMatrix4Mult($0.transform, placed))
                }
            }
            return preview(of: placements)
        }

        /// The mesh files a set of symbols draws, nesting included.
        func meshKeys(symdefs: Set<String>) -> Set<String> {
            Set(symdefs.flatMap { resolver.placements(forSymdef: $0, stack: []).map(\.meshKey) })
        }

        /// The mesh files a set of objects draws, through their symbols
        /// too.
        func meshKeys(objects keys: Set<String>) -> Set<String> {
            Set(keys.flatMap { placements(ofObject: $0).map(\.meshKey) })
        }

        /// Every object's model fingerprint and material colours, reading
        /// each mesh file once. Spread over the cores, like a simplify.
        func traits() -> [String: ObjectTraits] {
            var ownFiles: [String: [String]] = [:]
            var symbols: [String: [String]] = [:]
            var allMeshes: [String: Set<String>] = [:]
            var keys: Set<String> = []
            for (key, element) in objects {
                var own: [String] = []
                var placed: [String] = []
                for geometries in element.elements(forName: "Geometries") {
                    for case let child as XMLElement in geometries.children ?? [] {
                        if child.name == "Geometry3D", let file = child.attribute(forName: "fileName")?.stringValue {
                            own.append(file.lowercased())
                        } else if child.name == "Symbol", let symdef = child.attribute(forName: "symdef")?.stringValue {
                            placed.append(symdef.lowercased())
                        }
                    }
                }
                ownFiles[key] = own
                symbols[key] = placed
                let meshes = Set(placementsOf(element).map(\.meshKey)).union(own)
                allMeshes[key] = meshes
                keys.formUnion(meshes)
            }

            let files = Array(keys)
            let source = self.source
            nonisolated(unsafe) let sharedIndex = index
            let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
            var read = [(digest: String, colours: Set<UInt32>)](repeating: ("", []), count: files.count)
            read.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let slots = buffer
                DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                    guard let archive = try? Archive(url: source.url, accessMode: .read) else { return }
                    var position = worker
                    while position < files.count {
                        defer { position += workerCount }
                        let file = files[position]
                        var data = source.meshOverrides[file]
                        if data == nil, let entry = sharedIndex[file] {
                            var bytes = Data()
                            _ = try? archive.extract(entry) { bytes.append($0) }
                            data = bytes
                        }
                        guard let data else { continue }
                        slots[position] = (
                            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                            MeshFile.materialColours(data, fileName: file))
                    }
                }
            }
            var byFile: [String: (digest: String, colours: Set<UInt32>)] = [:]
            for (position, file) in files.enumerated() { byFile[file] = read[position] }

            var result: [String: ObjectTraits] = [:]
            for key in objects.keys {
                let own = (ownFiles[key] ?? []).map { byFile[$0]?.digest ?? $0 }.sorted()
                let placed = (symbols[key] ?? []).sorted()
                let model = own.isEmpty && placed.isEmpty
                    ? nil
                    : placed.joined(separator: ",") + "|" + own.joined(separator: ",")
                let colours = (allMeshes[key] ?? []).reduce(into: Set<UInt32>()) {
                    $0.formUnion(byFile[$1]?.colours ?? [])
                }
                result[key] = ObjectTraits(model: model, colours: colours)
            }
            return result
        }

        /// Triangles across a set of mesh files, each counted once.
        func triangleCount(meshKeys keys: Set<String>) -> Int {
            load(keys)
            return keys.reduce(0) { $0 + (meshes[$1]?.indices.count ?? 0) / 3 }
        }

        /// Rewrites each mesh file at about `fraction` of its triangles,
        /// in its own format. Spread over the cores: one real venue has
        /// over 12,000 meshes.
        func simplify(meshKeys keys: Set<String>, keeping fraction: Double) -> SimplifyResult {
            let keys = Array(keys)
            let source = self.source
            nonisolated(unsafe) let sharedIndex = index
            let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
            var outcomes = [(data: Data?, before: Int, after: Int)](repeating: (nil, 0, 0), count: keys.count)

            outcomes.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let slots = buffer
                DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                    guard let archive = try? Archive(url: source.url, accessMode: .read) else { return }
                    var position = worker
                    while position < keys.count {
                        defer { position += workerCount }
                        let key = keys[position]
                        var data = source.meshOverrides[key]
                        if data == nil, let entry = sharedIndex[key] {
                            var read = Data()
                            _ = try? archive.extract(entry) { read.append($0) }
                            data = read
                        }
                        guard let data, let mesh = MeshFile.read(data, fileName: key) else { continue }
                        let simpler = MeshSimplifier.simplify(mesh, keeping: fraction)
                        guard simpler.triangleCount < mesh.triangleCount,
                              let written = MeshFile.write(simpler, fileName: key)
                        else {
                            slots[position] = (nil, mesh.triangleCount, mesh.triangleCount)
                            continue
                        }
                        slots[position] = (written, mesh.triangleCount, simpler.triangleCount)
                    }
                }
            }

            var files: [String: Data] = [:]
            for (position, outcome) in outcomes.enumerated() {
                if let data = outcome.data { files[keys[position]] = data }
            }
            return SimplifyResult(
                files: files,
                trianglesBefore: outcomes.reduce(0) { $0 + $1.before },
                trianglesAfter: outcomes.reduce(0) { $0 + $1.after },
                meshCount: keys.count)
        }

        private func placements(ofObject key: String) -> [MeshPlacement] {
            objects[key].map(placementsOf) ?? []
        }

        private func placementsOf(_ element: XMLElement) -> [MeshPlacement] {
            var result: [MeshPlacement] = []
            for geometries in element.elements(forName: "Geometries") {
                resolver.collectPlacements(of: geometries, accumulated: SCNMatrix4Identity, into: &result, stack: [])
            }
            return result
        }

        private func load(_ keys: Set<String>) {
            let needed = keys.filter { meshes[$0] == nil && !unreadable.contains($0) }
            guard !needed.isEmpty else { return }
            let parsed = MVRSceneGeometryLoader.parseMeshes(
                keys: Array(needed), mvrURL: source.url, index: index, overrides: source.meshOverrides)
            meshes.merge(parsed) { first, _ in first }
            unreadable.formUnion(needed.filter { parsed[$0] == nil })
        }

        private func preview(of placements: [MeshPlacement]) -> SymbolPreview? {
            load(Set(placements.map(\.meshKey)))
            let chunks = MVRSceneGeometryLoader.mergedNodes(placements: placements, meshes: meshes)
            guard !chunks.isEmpty else { return nil }

            let root = SCNNode()
            var low = SCNVector3(CGFloat.infinity, .infinity, .infinity)
            var high = SCNVector3(-CGFloat.infinity, -.infinity, -.infinity)
            var triangles = 0
            for chunk in chunks {
                root.addChildNode(chunk)
                let (chunkLow, chunkHigh) = chunk.boundingBox
                low = SCNVector3(min(low.x, chunkLow.x), min(low.y, chunkLow.y), min(low.z, chunkLow.z))
                high = SCNVector3(max(high.x, chunkHigh.x), max(high.y, chunkHigh.y), max(high.z, chunkHigh.z))
                triangles += (chunk.geometry?.elements ?? []).reduce(0) { $0 + $1.primitiveCount }
            }
            root.enumerateHierarchy { node, _ in node.castsShadow = false }

            return SymbolPreview(
                node: root,
                boundingBox: (low, high),
                triangleCount: triangles,
                meshPlacementCount: placements.count,
                missingMeshCount: placements.filter { meshes[$0.meshKey] == nil }.count)
        }
    }
}
