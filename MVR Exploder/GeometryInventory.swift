import Foundation

/// The file's reusable geometry — its symbol definitions — and how many
/// times each one is placed.
///
/// A symbol (`<AUXData><Symdef>`) is the closest thing an MVR has to a
/// named piece of geometry: "Slick Super Beam 3.0m", "Kara", "Tom Cat
/// 20.5in Pin 10ft". Objects place it with `<Symbol symdef=…>`. The
/// `<Geometry3D>` files themselves aren't worth listing on their own:
/// across real files every one is referenced exactly once, each object or
/// symbol shipping its own copy of the mesh.
///
/// Symbols nest, so a symbol used inside another counts once per placement
/// of its parent: a clamp in a truss symbol placed 40 times is used 40
/// times, not once.
nonisolated struct GeometryInventory: Sendable {
    struct Usage: Sendable, Hashable {
        /// "trusses", "scene objects", "inside “Tower”".
        let label: String
        let count: Int
    }

    struct Item: Identifiable, Sendable, Hashable {
        /// The symdef's uuid, lowercased.
        let id: String
        let name: String
        /// Times placed in the scene, nesting included.
        let uses: Int
        /// Where those uses come from, most first.
        let usage: [Usage]
        /// `<Geometry3D>` meshes the symbol holds directly.
        let meshCount: Int
        /// Other symbols placed inside this one.
        let nestedSymbolCount: Int
        /// The tags of the objects that place it, through other symbols
        /// too — what the type filter matches on.
        let kinds: Set<String>
    }

    /// One object that can carry geometry: a scene object, truss, support,
    /// video screen, projector or focus point.
    struct Object: Identifiable, Sendable, Hashable {
        /// Its key, as `MVRSceneGeometryLoader.objectKeys(_:)` gives it:
        /// the uuid, so it survives renames, moves and deletes around it.
        let id: String
        /// Its place among the file's objects, for listing in file order.
        let order: Int
        let name: String
        /// The element name: "Truss", "SceneObject"…
        let kind: String
        let layer: String
        let layerUUID: String
        /// Where its `<Matrix>` puts it, in millimetres; nil without one.
        let position: SIMD3<Double>?
        /// Fixtures sit inside it, as in a scene object used as a
        /// container. Those move with it, so it isn't moved between
        /// layers here.
        let holdsFixtures: Bool
        /// The symbols it places, by name, in the order it places them.
        let models: [String]
        /// Meshes it carries itself rather than through a symbol.
        let ownMeshCount: Int

        /// What the Model column shows.
        var modelSummary: String {
            var parts = models
            if ownMeshCount > 0 {
                parts.append(ownMeshCount == 1 ? "Own mesh" : "\(ownMeshCount) own meshes")
            }
            return parts.isEmpty ? "—" : parts.joined(separator: ", ")
        }
    }

    let items: [Item]
    let objects: [Object]
    /// Objects carrying their own one-off meshes rather than a symbol, so
    /// not in `items`.
    let looseObjectCount: Int

    static let empty = GeometryInventory(items: [], objects: [], looseObjectCount: 0)

    /// `objects` are the file's geometry objects in document order, as
    /// `MVRSceneGeometryLoader.geometryObjectsXPath` finds them; read here
    /// when not given.
    static func read(_ xmlDocument: XMLDocument, objects: [XMLElement]? = nil) -> GeometryInventory {
        guard let root = xmlDocument.rootElement() else { return .empty }
        let objectElements = objects
            ?? ((try? xmlDocument.nodes(forXPath: MVRSceneGeometryLoader.geometryObjectsXPath)) ?? [])
                .compactMap { $0 as? XMLElement }

        var names: [String: String] = [:]
        var order: [String] = []
        var meshCounts: [String: Int] = [:]
        var nestedCounts: [String: Int] = [:]
        /// Symdef → owning object's tag → placements outside any symdef.
        var topUses: [String: [String: Int]] = [:]
        /// Symdef → parent symdef → placements inside that parent.
        var nestedUses: [String: [String: Int]] = [:]
        var looseObjects = 0

        /// `symdef` is the symbol being read, if any; `owner` the tag of
        /// the object whose `<Geometries>` this is in.
        func walk(_ element: XMLElement, symdef: String?, owner: String?) {
            for case let child as XMLElement in element.children ?? [] {
                switch child.name {
                case "Symdef":
                    guard let uuid = child.attribute(forName: "uuid")?.stringValue?.lowercased() else { continue }
                    if names[uuid] == nil { order.append(uuid) }
                    names[uuid] = displayName(child.attribute(forName: "name")?.stringValue)
                    walk(child, symdef: uuid, owner: nil)

                case "Symbol":
                    guard let target = child.attribute(forName: "symdef")?.stringValue?.lowercased() else { continue }
                    if let symdef {
                        nestedUses[target, default: [:]][symdef, default: 0] += 1
                        nestedCounts[symdef, default: 0] += 1
                    } else {
                        topUses[target, default: [:]][owner ?? "", default: 0] += 1
                    }

                case "Geometry3D":
                    if let symdef { meshCounts[symdef, default: 0] += 1 }

                case "Geometries":
                    if symdef == nil, !child.elements(forName: "Geometry3D").isEmpty {
                        looseObjects += 1
                    }
                    walk(child, symdef: symdef, owner: element.name)

                default:
                    walk(child, symdef: symdef, owner: owner)
                }
            }
        }
        walk(root, symdef: nil, owner: nil)

        var totals: [String: Int] = [:]
        /// Placements of a symdef in the scene. `stack` stops a symbol
        /// that contains itself from recursing forever.
        func total(_ uuid: String, stack: Set<String>) -> Int {
            if let known = totals[uuid] { return known }
            guard !stack.contains(uuid) else { return 0 }
            var count = topUses[uuid]?.values.reduce(0, +) ?? 0
            for (parent, times) in nestedUses[uuid] ?? [:] {
                count += times * total(parent, stack: stack.union([uuid]))
            }
            totals[uuid] = count
            return count
        }

        var kindsMemo: [String: Set<String>] = [:]
        /// The object tags placing a symdef, through its parents.
        func kinds(_ uuid: String, stack: Set<String>) -> Set<String> {
            if let known = kindsMemo[uuid] { return known }
            guard !stack.contains(uuid) else { return [] }
            var result = Set((topUses[uuid] ?? [:]).keys.filter { !$0.isEmpty })
            for parent in (nestedUses[uuid] ?? [:]).keys {
                result.formUnion(kinds(parent, stack: stack.union([uuid])))
            }
            kindsMemo[uuid] = result
            return result
        }

        let items = order.map { uuid -> Item in
            var usage = (topUses[uuid] ?? [:]).map { tag, count in
                Usage(label: objectLabel(tag, count: count), count: count)
            }
            for (parent, times) in nestedUses[uuid] ?? [:] {
                usage.append(Usage(
                    label: "inside “\(names[parent] ?? "another symbol")”",
                    count: times * total(parent, stack: [uuid])))
            }
            usage.sort { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }

            return Item(
                id: uuid,
                name: names[uuid] ?? "",
                uses: total(uuid, stack: []),
                usage: usage,
                meshCount: meshCounts[uuid] ?? 0,
                nestedSymbolCount: nestedCounts[uuid] ?? 0,
                kinds: kinds(uuid, stack: []))
        }

        let keys = MVRSceneGeometryLoader.objectKeys(objectElements)
        let objectList = objectElements.enumerated().map { number, element -> Object in
            var models: [String] = []
            var ownMeshes = 0
            for geometries in element.elements(forName: "Geometries") {
                for case let child as XMLElement in geometries.children ?? [] {
                    if child.name == "Symbol",
                       let target = child.attribute(forName: "symdef")?.stringValue?.lowercased() {
                        models.append(names[target] ?? "Missing symbol")
                    } else if child.name == "Geometry3D" {
                        ownMeshes += 1
                    }
                }
            }
            let name = element.attribute(forName: "name")?.stringValue?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let layer = owningLayer(of: element)
            return Object(
                id: keys[number],
                order: number,
                name: name.isEmpty ? "Unnamed" : name,
                kind: element.name ?? "",
                layer: layer.name,
                layerUUID: layer.uuid,
                position: element.elements(forName: "Matrix").first?.stringValue
                    .flatMap(MVRSceneGeometryLoader.translation(ofMatrixText:)),
                holdsFixtures: holdsFixture(element),
                models: models,
                ownMeshCount: ownMeshes)
        }
        return GeometryInventory(items: items, objects: objectList, looseObjectCount: looseObjects)
    }

    private static func owningLayer(of element: XMLElement) -> (name: String, uuid: String) {
        var current = element.parent as? XMLElement
        while let node = current {
            if node.name == "Layer" {
                return (node.attribute(forName: "name")?.stringValue ?? "",
                        node.attribute(forName: "uuid")?.stringValue ?? "")
            }
            current = node.parent as? XMLElement
        }
        return ("", "")
    }

    /// Walked by hand: Foundation's relative XPath can run past the
    /// element it starts from.
    private static func holdsFixture(_ element: XMLElement) -> Bool {
        (element.children ?? []).contains { child in
            guard let child = child as? XMLElement else { return false }
            return child.name == "Fixture" || holdsFixture(child)
        }
    }

    /// "Truss", "Scene object": one object's type.
    static func kindName(_ tag: String) -> String {
        let label = objectLabel(tag, count: 1)
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// "Trusses", "Scene objects": a type's name as a filter shows it.
    static func kindLabel(_ tag: String) -> String {
        let label = objectLabel(tag, count: 2)
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Vectorworks names every symdef "Symbol Definition for …", which is
    /// noise in a list made of nothing else.
    private static func displayName(_ raw: String?) -> String {
        var name = (raw ?? "").trimmingCharacters(in: .whitespaces)
        let prefix = "Symbol Definition for "
        if name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? "Unnamed symbol" : name
    }

    private static func objectLabel(_ tag: String, count: Int) -> String {
        let singular: String
        switch tag {
        case "Truss": return count == 1 ? "truss" : "trusses"
        case "SceneObject": singular = "scene object"
        case "VideoScreen": singular = "video screen"
        case "FocusPoint": singular = "focus point"
        case "": singular = "other object"
        default: singular = tag.lowercased()
        }
        return count == 1 ? singular : singular + "s"
    }
}
