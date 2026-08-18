import Foundation
import SceneKit
import AppKit
import ZIPFoundation

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

// MARK: - 3DS scene meshes

extension GDTF3DSParser.RawMesh {
    /// Builds geometry from a scene-geometry `.3ds` file. Unlike GDTF's
    /// unit-normalised fixture models, these meshes carry real-world
    /// coordinates in millimetres in the MVR's own Z-up frame, so vertices
    /// are converted to this app's scene convention (metres, Y up) with the
    /// same remap used for fixture positions.
    func buildSceneGeometry() -> SCNGeometry? {
        guard vertices.count >= 3, faceIndices.count >= 3 else { return nil }
        let converted = vertices.map { SCNVector3($0.x / 1000, $0.z / 1000, -$0.y / 1000) }
        let element = SCNGeometryElement(indices: faceIndices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: converted)], elements: [element])
        geometry.materials = [MVRSceneGeometryLoader.makeSceneMaterial()]
        return geometry
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
        buildNode(mvrURL: url)
    }

    private nonisolated static func buildNode(mvrURL url: URL) -> LoadedGeometry {
        let empty = LoadedGeometry(node: nil, layers: [], objects: [])
        guard let archive = try? Archive(url: url, accessMode: .read) else { return empty }
        guard let sceneEntry = archive["GeneralSceneDescription.xml"] else { return empty }
        var xmlData = Data()
        _ = try? archive.extract(sceneEntry) { xmlData.append($0) }
        guard let xmlDocument = try? XMLDocument(data: xmlData, options: []) else { return empty }

        // Index every symdef by uuid so <Symbol symdef="…"> can resolve.
        var symdefElements: [String: XMLElement] = [:]
        for case let element as XMLElement in (try? xmlDocument.nodes(forXPath: "//Symdef")) ?? [] {
            if let uuid = element.attribute(forName: "uuid")?.stringValue?.lowercased() {
                symdefElements[uuid] = element
            }
        }

        var meshCache: [String: SCNNode?] = [:]
        var symdefTemplates: [String: SCNNode?] = [:]

        // Index the archive up front. Scanning it per lookup instead is
        // quadratic — one real file has 3871 entries and ~3800 distinct
        // mesh references, which took over a minute on its own.
        var entriesByName: [String: Entry] = [:]
        for entry in archive {
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            if entriesByName[name] == nil { entriesByName[name] = entry }
        }

        /// Reads and parses one geometry file from the archive, caching by
        /// name — the same mesh is typically referenced many times.
        func meshNode(fileName: String) -> SCNNode? {
            let key = fileName.lowercased()
            if let cached = meshCache[key] { return cached }

            var result: SCNNode?
            if let entry = entriesByName[key] {
                var data = Data()
                _ = try? archive.extract(entry) { data.append($0) }
                if !data.isEmpty {
                    if key.hasSuffix(".glb") || key.hasSuffix(".gltf") {
                        result = GLBParser.parse(data)
                    } else if key.hasSuffix(".3ds") {
                        if let mesh = GDTF3DSParser.parse(data), let geometry = mesh.buildSceneGeometry() {
                            result = SCNNode(geometry: geometry)
                        }
                    }
                }
            }
            meshCache[key] = .some(result)
            return result
        }

        /// Builds (or returns a cached) template for one symdef. `stack`
        /// guards against a symdef that transitively references itself,
        /// which would otherwise recurse forever.
        func symdefTemplate(uuid: String, stack: Set<String>) -> SCNNode? {
            let key = uuid.lowercased()
            if let cached = symdefTemplates[key] { return cached }
            guard !stack.contains(key), let element = symdefElements[key] else { return nil }

            let container = SCNNode()
            appendChildren(of: element, to: container, stack: stack.union([key]))
            let result: SCNNode? = container.childNodes.isEmpty ? nil : container
            symdefTemplates[key] = .some(result)
            return result
        }

        /// Walks an element's descendants for the two things that produce
        /// geometry — direct `<Geometry3D>` file references and `<Symbol>`
        /// symdef instances — and adds a node for each.
        func appendChildren(of element: XMLElement, to parent: SCNNode, stack: Set<String>) {
            for case let child as XMLElement in element.children ?? [] {
                switch child.name {
                case "Geometry3D":
                    guard
                        let fileName = child.attribute(forName: "fileName")?.stringValue,
                        let mesh = meshNode(fileName: fileName)
                    else { continue }
                    let node = mesh.clone()
                    if let matrix = transform(from: child) {
                        node.transform = matrix
                    }
                    parent.addChildNode(node)

                case "Symbol":
                    guard
                        let symdefUUID = child.attribute(forName: "symdef")?.stringValue,
                        let template = symdefTemplate(uuid: symdefUUID, stack: stack)
                    else { continue }
                    let node = template.clone()
                    if let matrix = transform(from: child) {
                        node.transform = matrix
                    }
                    parent.addChildNode(node)

                default:
                    // Containers such as <ChildList> and <Geometries> just
                    // nest the elements above.
                    appendChildren(of: child, to: parent, stack: stack)
                }
            }
        }

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

        for case let sceneObject as XMLElement in (try? xmlDocument.nodes(forXPath: "//SceneObject")) ?? [] {
            let node = SCNNode()
            if let matrix = transform(from: sceneObject) {
                node.transform = matrix
            }
            appendChildren(of: sceneObject, to: node, stack: [])
            guard !node.childNodes.isEmpty else { continue }

            let layer = owningLayer(of: sceneObject)
            let key = layer.uuid.lowercased()

            // Index-based rather than the SceneObject's own uuid: the uuid
            // is optional and not guaranteed unique across a file, and this
            // id only has to be stable for the lifetime of one load.
            let objectID = "\(SceneGeometryObject.nodeNamePrefix)\(objects.count)"
            node.name = objectID
            objects.append(SceneGeometryObject(
                id: objectID,
                name: sceneObject.attribute(forName: "name")?.stringValue ?? "Object",
                layerUUID: key))
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
