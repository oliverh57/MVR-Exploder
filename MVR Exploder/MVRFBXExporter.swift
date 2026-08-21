import Foundation
import SceneKit

/// Writes selected scene geometry out as an FBX.
///
/// **Binary FBX 7.4, written directly.** FBX is Autodesk's format and the
/// only complete implementation is their C++ SDK, which is licence-gated
/// and can't be embedded here — but the binary container is documented
/// well enough to write, and a mesh needs only a small part of it: a
/// `Geometry` holding vertices and polygons, a `Model` to place it, and a
/// `Connections` block tying them to the scene root.
///
/// Binary rather than the far simpler ASCII form for one blunt reason:
/// **Blender refuses ASCII FBX** — its importer rejects the file outright
/// rather than reading it — and Blender is the likeliest place this
/// geometry is going. Binary reads everywhere ASCII does, and there.
///
/// No cameras, lights, materials, animation or skinning — none of which
/// the viewer has.
///
/// **Units are centimetres**, which is FBX's own native unit, with
/// `UnitScaleFactor` 1.0. Metres with a scale factor of 100 is equally
/// legal and reads correctly in anything that honours the factor, but an
/// importer that ignores it assumes centimetres — so writing centimetres
/// is the option that survives being misread.
///
/// Axes are left as the viewer has them, **Y up, Z toward the viewer**,
/// which is already FBX's default orientation.
enum MVRFBXExporter {

    typealias ExportItem = MVRGeometryExport.ExportItem
    typealias ExportSummary = MVRGeometryExport.ExportSummary

    private static let version: UInt32 = 7400
    /// FBX carries no unit tag on the geometry itself, only the header
    /// factor, so the numbers written have to be in the unit declared.
    private static let metresToCentimetres = 100.0

    @discardableResult
    static func export(items: [ExportItem], to url: URL) throws -> ExportSummary {
        let meshes = MVRGeometryExport.meshes(for: items)
        guard !meshes.isEmpty else { throw MVRGeometryExportError.nothingToExport }

        let root = Node(name: "")
        root.children.append(headerExtension())
        root.children.append(globalSettings())
        root.children.append(definitions(objectCount: meshes.count))

        let objects = Node(name: "Objects")
        let connections = Node(name: "Connections")
        var totalTriangles = 0
        var totalVertices = 0
        // Object ids only have to be unique within the file and non-zero —
        // zero is the scene root, which everything hangs off.
        var nextID: Int64 = 1_000_000
        var usedNames: Set<String> = []

        for mesh in meshes {
            let name = uniqueName(mesh.name, index: mesh.index, used: &usedNames)
            let geometryID = nextID; nextID += 1
            let modelID = nextID; nextID += 1

            objects.children.append(geometryNode(mesh, id: geometryID, name: name))
            objects.children.append(modelNode(id: modelID, name: name))

            // "OO" is an object-object link.
            connections.children.append(
                Node(name: "C", properties: [.string("OO"), .int64(modelID), .int64(0)]))
            connections.children.append(
                Node(name: "C", properties: [.string("OO"), .int64(geometryID), .int64(modelID)]))

            totalTriangles += mesh.triangleCount
            totalVertices += mesh.vertexCount
        }

        root.children.append(objects)
        root.children.append(connections)

        var data = Data()
        data.reserveCapacity(totalVertices * 32 + totalTriangles * 16 + 4096)
        appendHeader(&data)
        for child in root.children { encode(child, into: &data) }
        // A zero end-offset is what tells a reader the root list is over.
        data.append(Data(count: nullRecordLength))
        appendFooter(&data)

        try data.write(to: url, options: .atomic)
        return ExportSummary(
            objectCount: meshes.count, triangleCount: totalTriangles, vertexCount: totalVertices)
    }

    // MARK: - Document

    private static func headerExtension() -> Node {
        let node = Node(name: "FBXHeaderExtension")
        node.children = [
            Node(name: "FBXHeaderVersion", properties: [.int32(1003)]),
            Node(name: "FBXVersion", properties: [.int32(Int32(version))]),
            Node(name: "Creator", properties: [.string("MVR Exploder")]),
        ]
        return node
    }

    private static func globalSettings() -> Node {
        let properties = Node(name: "Properties70")
        properties.children = [
            property("UpAxis", "int", "Integer", .int32(1)),
            property("UpAxisSign", "int", "Integer", .int32(1)),
            property("FrontAxis", "int", "Integer", .int32(2)),
            property("FrontAxisSign", "int", "Integer", .int32(1)),
            property("CoordAxis", "int", "Integer", .int32(0)),
            property("CoordAxisSign", "int", "Integer", .int32(1)),
            property("OriginalUpAxis", "int", "Integer", .int32(1)),
            property("OriginalUpAxisSign", "int", "Integer", .int32(1)),
            property("UnitScaleFactor", "double", "Number", .double(1)),
            property("OriginalUnitScaleFactor", "double", "Number", .double(1)),
        ]

        let node = Node(name: "GlobalSettings")
        node.children = [Node(name: "Version", properties: [.int32(1000)]), properties]
        return node
    }

    private static func definitions(objectCount: Int) -> Node {
        func objectType(_ name: String, count: Int) -> Node {
            let node = Node(name: "ObjectType", properties: [.string(name)])
            node.children = [Node(name: "Count", properties: [.int32(Int32(count))])]
            return node
        }

        let node = Node(name: "Definitions")
        node.children = [
            Node(name: "Version", properties: [.int32(100)]),
            Node(name: "Count", properties: [.int32(Int32(objectCount * 2 + 1))]),
            objectType("GlobalSettings", count: 1),
            objectType("Geometry", count: objectCount),
            objectType("Model", count: objectCount),
        ]
        return node
    }

    private static func geometryNode(
        _ mesh: MVRGeometryExport.Mesh, id: Int64, name: String
    ) -> Node {
        var vertices: [Double] = []
        var indices: [Int32] = []
        var normals: [Double] = []
        vertices.reserveCapacity(mesh.vertexCount * 3)
        indices.reserveCapacity(mesh.triangleCount * 3)

        let writeNormals = mesh.hasNormals
        if writeNormals { normals.reserveCapacity(mesh.vertexCount * 3) }

        var base = 0
        for part in mesh.parts {
            for position in part.positions {
                vertices.append(Double(position.x) * metresToCentimetres)
                vertices.append(Double(position.y) * metresToCentimetres)
                vertices.append(Double(position.z) * metresToCentimetres)
            }
            if writeNormals {
                for normal in part.normals {
                    normals.append(Double(normal.x))
                    normals.append(Double(normal.y))
                    normals.append(Double(normal.z))
                }
            }
            for triangle in part.triangles {
                indices.append(Int32(base + triangle.a))
                indices.append(Int32(base + triangle.b))
                // The last index of each polygon is stored as its bitwise
                // complement — that, and nothing else, is what marks where
                // one polygon ends and the next begins.
                indices.append(~Int32(base + triangle.c))
            }
            base += part.positions.count
        }

        let node = Node(
            name: "Geometry",
            properties: [.int64(id), .objectName(name, class: "Geometry"), .string("Mesh")])
        node.children = [
            Node(name: "Vertices", properties: [.doubleArray(vertices)]),
            Node(name: "PolygonVertexIndex", properties: [.int32Array(indices)]),
            Node(name: "GeometryVersion", properties: [.int32(124)]),
        ]

        if writeNormals {
            let layerElement = Node(name: "LayerElementNormal", properties: [.int32(0)])
            layerElement.children = [
                Node(name: "Version", properties: [.int32(102)]),
                Node(name: "Name", properties: [.string("")]),
                Node(name: "MappingInformationType", properties: [.string("ByVertice")]),
                Node(name: "ReferenceInformationType", properties: [.string("Direct")]),
                Node(name: "Normals", properties: [.doubleArray(normals)]),
            ]

            let entry = Node(name: "LayerElement")
            entry.children = [
                Node(name: "Type", properties: [.string("LayerElementNormal")]),
                Node(name: "TypedIndex", properties: [.int32(0)]),
            ]
            let layer = Node(name: "Layer", properties: [.int32(0)])
            layer.children = [Node(name: "Version", properties: [.int32(100)]), entry]

            node.children.append(layerElement)
            node.children.append(layer)
        }

        return node
    }

    private static func modelNode(id: Int64, name: String) -> Node {
        let node = Node(
            name: "Model",
            properties: [.int64(id), .objectName(name, class: "Model"), .string("Mesh")])
        node.children = [
            Node(name: "Version", properties: [.int32(232)]),
            Node(name: "Properties70"),
            Node(name: "Shading", properties: [.bool(true)]),
            Node(name: "Culling", properties: [.string("CullingOff")]),
        ]
        return node
    }

    private static func property(
        _ name: String, _ type: String, _ subtype: String, _ value: Property
    ) -> Node {
        Node(name: "P", properties: [.string(name), .string(type), .string(subtype), .string(""), value])
    }

    // MARK: - Node tree

    private final class Node {
        let name: String
        var properties: [Property]
        var children: [Node] = []

        init(name: String, properties: [Property] = []) {
            self.name = name
            self.properties = properties
        }
    }

    private enum Property {
        case int32(Int32)
        case int64(Int64)
        case double(Double)
        case bool(Bool)
        case string(String)
        /// An object's name, which binary FBX stores as `name\0\1Class`
        /// rather than the `Class::name` the text form uses.
        case objectName(String, `class`: String)
        case doubleArray([Double])
        case int32Array([Int32])
    }

    // MARK: - Encoding

    private static let nullRecordLength = 13

    private static func appendHeader(_ data: inout Data) {
        data.append(contentsOf: Array("Kaydara FBX Binary  ".utf8))
        data.append(contentsOf: [0x00, 0x1A, 0x00])
        append(UInt32(version), to: &data)
    }

    /// The 16 bytes ahead of the footer proper are undocumented; this is
    /// the constant assimp writes, and files carrying it are read by every
    /// importer that checks at all.
    private static let footerID: [UInt8] = [
        0xFA, 0xBC, 0xAB, 0x09, 0xD0, 0xC8, 0xD4, 0x66,
        0xB1, 0x76, 0xFB, 0x83, 0x1C, 0xF7, 0x26, 0x7E,
    ]

    private static let footerMagic: [UInt8] = [
        0xF8, 0x5A, 0x8C, 0x6A, 0xDE, 0xF5, 0xD9, 0x7E,
        0xEC, 0xE9, 0x0C, 0xE3, 0x75, 0x05, 0x0B, 0xD0,
    ]

    private static func appendFooter(_ data: inout Data) {
        data.append(contentsOf: footerID)
        // The block that follows has to start on a 16-byte boundary.
        let padding = (16 - data.count % 16) % 16
        data.append(Data(count: padding == 0 ? 16 : padding))
        append(UInt32(0), to: &data)
        append(UInt32(version), to: &data)
        data.append(Data(count: 120))
        data.append(contentsOf: footerMagic)
    }

    /// Writes one record. `EndOffset` is an absolute file offset, so the
    /// field is left blank and patched once the record's true extent is
    /// known — the alternative is measuring every subtree twice.
    private static func encode(_ node: Node, into data: inout Data) {
        let start = data.count
        append(UInt32(0), to: &data)

        var propertyData = Data()
        for property in node.properties { encode(property, into: &propertyData) }

        append(UInt32(node.properties.count), to: &data)
        append(UInt32(propertyData.count), to: &data)
        let nameBytes = Array(node.name.utf8)
        data.append(UInt8(min(nameBytes.count, 255)))
        data.append(contentsOf: nameBytes.prefix(255))
        data.append(propertyData)

        if !node.children.isEmpty {
            for child in node.children { encode(child, into: &data) }
            // Only when there are children: a reader takes the sentinel's
            // presence from the record's extent, and an empty node that
            // wrote one would overrun its own end offset.
            data.append(Data(count: nullRecordLength))
        }

        let end = UInt32(data.count)
        withUnsafeBytes(of: end.littleEndian) { bytes in
            data.replaceSubrange(start..<(start + 4), with: bytes)
        }
    }

    private static func encode(_ property: Property, into data: inout Data) {
        switch property {
        case let .int32(value):
            data.append(UInt8(ascii: "I"))
            append(UInt32(bitPattern: value), to: &data)
        case let .int64(value):
            data.append(UInt8(ascii: "L"))
            append(UInt64(bitPattern: value), to: &data)
        case let .double(value):
            data.append(UInt8(ascii: "D"))
            append(value.bitPattern, to: &data)
        case let .bool(value):
            data.append(UInt8(ascii: "C"))
            data.append(value ? 1 : 0)
        case let .string(value):
            appendString(Array(value.utf8), to: &data)
        case let .objectName(name, className):
            var bytes = Array(name.utf8)
            bytes.append(contentsOf: [0x00, 0x01])
            bytes.append(contentsOf: Array(className.utf8))
            appendString(bytes, to: &data)
        case let .doubleArray(values):
            data.append(UInt8(ascii: "d"))
            appendArrayHeader(count: values.count, byteCount: values.count * 8, to: &data)
            values.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        case let .int32Array(values):
            data.append(UInt8(ascii: "i"))
            appendArrayHeader(count: values.count, byteCount: values.count * 4, to: &data)
            values.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        }
    }

    private static func appendString(_ bytes: [UInt8], to data: inout Data) {
        data.append(UInt8(ascii: "S"))
        append(UInt32(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    /// Encoding 0 is uncompressed. FBX also allows zlib, which would make
    /// the file smaller but needs a zlib-wrapped stream built by hand —
    /// not worth it for a format that is read once and thrown away.
    private static func appendArrayHeader(count: Int, byteCount: Int, to data: inout Data) {
        append(UInt32(count), to: &data)
        append(UInt32(0), to: &data)
        append(UInt32(byteCount), to: &data)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Duplicates are numbered: two objects sharing a name is legal FBX but
    /// makes a scene tree no one can navigate.
    private static func uniqueName(_ name: String, index: Int, used: inout Set<String>) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "object_\(index)" }

        var candidate = cleaned
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(cleaned) (\(suffix))"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }
}
