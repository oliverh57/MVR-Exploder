import Foundation
import SceneKit
import AppKit

/// One proposed group, ready to draw: its fixtures in numbering order, the
/// colour it was given, and what to label it.
struct AutoIDGroupOverlay {
    let label: String
    let color: NSColor
    /// Fixture ids in the order they'd be numbered.
    let fixtureIDs: [String]
}

/// Draws the proposed grouping into the 3D scene.
///
/// Colour alone answers "which group is this fixture in" but not the two
/// questions that actually matter when checking a run: where does one group
/// stop and the next begin, and which way do the numbers run along it. So
/// each group gets a wireframe box around its extent and a path threaded
/// through its fixtures in numbering order, with arrowheads along the way.
enum AutoIDOverlayBuilder {

    /// Padding around a group's fixtures, so the box doesn't sit exactly on
    /// the outermost fixture and disappear into it.
    private static let boxPadding: CGFloat = 0.25

    static func node(groups: [AutoIDGroupOverlay], positions: [String: SCNVector3]) -> SCNNode {
        let root = SCNNode()
        root.name = "autoIDOverlay"

        for (index, group) in groups.enumerated() {
            let points = group.fixtureIDs.compactMap { positions[$0] }
            guard !points.isEmpty else { continue }

            let container = SCNNode()
            container.addChildNode(boxNode(around: points, color: group.color))

            // A filled version of the same box, kept hidden until the
            // cursor is over the group. The wireframe alone is hard to
            // pick out among a dozen others; a solid face says which one
            // you are actually pointing at.
            let solid = solidNode(around: points, color: group.color)
            solid.name = Self.solidNodeName
            solid.isHidden = true
            container.addChildNode(solid)

            if points.count > 1 {
                container.addChildNode(pathNode(through: points, color: group.color))
                for arrow in arrowNodes(along: points, color: group.color) {
                    container.addChildNode(arrow)
                }
            }
            // A dot at the first fixture, so "which end does it start" is
            // answerable even on a group whose path is short.
            container.addChildNode(startNode(at: points[0], color: group.color))
            container.addChildNode(labelNode(group.label, above: points, color: group.color))

            container.name = "\(Self.groupNodePrefix)\(index)"
            root.addChildNode(container)
        }

        // Overlay lines are guides, not part of the rig — and they must be
        // drawn last, on top of everything, or they're invisible: the path
        // threads through fixture *centres*, so with normal depth testing
        // the line and its arrowheads end up buried inside the fixture
        // bodies they connect. Only the padded boxes escaped, which is why
        // the grouping showed but the direction arrows didn't.
        root.enumerateHierarchy { node, _ in
            node.castsShadow = false
            node.renderingOrder = 1_000
        }
        return root
    }

    // MARK: - Pieces

    /// Names the preview uses to find a group's container and its fill.
    static let groupNodePrefix = "autoid-group-"
    static let solidNodeName = "autoid-solid"

    /// The same padded box as the wireframe, but faced.
    private static func solidNode(around points: [SCNVector3], color: NSColor) -> SCNNode {
        let xs = points.map(\.x), ys = points.map(\.y), zs = points.map(\.z)
        let low = SCNVector3((xs.min() ?? 0) - boxPadding, (ys.min() ?? 0) - boxPadding, (zs.min() ?? 0) - boxPadding)
        let high = SCNVector3((xs.max() ?? 0) + boxPadding, (ys.max() ?? 0) + boxPadding, (zs.max() ?? 0) + boxPadding)

        // Explicit vertices rather than SCNBox, whose buffer is unit-sized
        // regardless of the dimensions asked for.
        let box = SCNGeometryMerge.boxGeometry(
            width: CGFloat(max(high.x - low.x, 0.01)),
            height: CGFloat(max(high.y - low.y, 0.01)),
            length: CGFloat(max(high.z - low.z, 0.01)))

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        // Faint enough to read the fixtures through, strong enough to see
        // at a glance. Node opacity dims it further for a mere hover, so
        // a selected box stays clearly the stronger of the two.
        material.transparency = 0.6
        material.isDoubleSided = true
        // Annotation, not geometry: it must not occlude the fixtures it
        // wraps, exactly like the wireframe and arrows.
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        box.materials = [material]

        let node = SCNNode(geometry: box)
        node.position = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
        node.renderingOrder = 999
        return node
    }

    private static func boxNode(around points: [SCNVector3], color: NSColor) -> SCNNode {
        let xs = points.map(\.x), ys = points.map(\.y), zs = points.map(\.z)
        let low = SCNVector3((xs.min() ?? 0) - boxPadding, (ys.min() ?? 0) - boxPadding, (zs.min() ?? 0) - boxPadding)
        let high = SCNVector3((xs.max() ?? 0) + boxPadding, (ys.max() ?? 0) + boxPadding, (zs.max() ?? 0) + boxPadding)

        let corners = [
            SCNVector3(low.x, low.y, low.z), SCNVector3(high.x, low.y, low.z),
            SCNVector3(high.x, low.y, high.z), SCNVector3(low.x, low.y, high.z),
            SCNVector3(low.x, high.y, low.z), SCNVector3(high.x, high.y, low.z),
            SCNVector3(high.x, high.y, high.z), SCNVector3(low.x, high.y, high.z),
        ]
        let edges: [Int32] = [
            0, 1, 1, 2, 2, 3, 3, 0,   // bottom
            4, 5, 5, 6, 6, 7, 7, 4,   // top
            0, 4, 1, 5, 2, 6, 3, 7,   // uprights
        ]
        return SCNNode(geometry: lineGeometry(points: corners, indices: edges, color: color))
    }

    /// The numbering order, drawn as a polyline through the fixtures.
    private static func pathNode(through points: [SCNVector3], color: NSColor) -> SCNNode {
        var indices: [Int32] = []
        for index in 0..<(points.count - 1) {
            indices.append(Int32(index))
            indices.append(Int32(index + 1))
        }
        return SCNNode(geometry: lineGeometry(points: points, indices: indices, color: color))
    }

    /// Arrowheads along the path. Spaced out rather than one per segment —
    /// a 28-fixture truss would otherwise be a solid line of cones — but
    /// always including the final segment, which is what shows the end.
    private static func arrowNodes(along points: [SCNVector3], color: NSColor) -> [SCNNode] {
        let segments = points.count - 1
        let wanted = min(segments, max(1, segments / 4))
        let step = max(1, segments / wanted)

        var indices = Array(stride(from: 0, to: segments, by: step))
        if indices.last != segments - 1 { indices.append(segments - 1) }

        return indices.compactMap { index in
            let start = points[index], end = points[index + 1]
            let direction = SCNVector3(end.x - start.x, end.y - start.y, end.z - start.z)
            let length = (direction.x * direction.x + direction.y * direction.y + direction.z * direction.z).squareRoot()
            guard length > 0.001 else { return nil }

            // Sized off the gap it sits in, so arrows stay legible whether
            // fixtures are 0.5m or 20m apart. The floor matters most on
            // tightly-packed pixel bars, where a proportional arrow would
            // shrink to nothing.
            let size = min(max(length * 0.35, 0.14), 0.7)
            let cone = SCNCone(topRadius: 0, bottomRadius: size * 0.35, height: size)
            cone.materials = [overlayMaterial(color)]

            let node = SCNNode(geometry: cone)
            node.position = SCNVector3(
                start.x + direction.x * 0.5,
                start.y + direction.y * 0.5,
                start.z + direction.z * 0.5)
            node.rotation = rotationAligningUp(with: direction, length: length)
            return node
        }
    }

    private static func startNode(at point: SCNVector3, color: NSColor) -> SCNNode {
        let sphere = SCNSphere(radius: 0.09)
        sphere.materials = [overlayMaterial(color)]
        let node = SCNNode(geometry: sphere)
        node.position = point
        return node
    }

    private static func labelNode(_ text: String, above points: [SCNVector3], color: NSColor) -> SCNNode {
        let label = SCNText(string: text, extrusionDepth: 0)
        label.font = .systemFont(ofSize: 8, weight: .semibold)
        label.flatness = 0.4
        label.materials = [overlayMaterial(color)]

        let node = SCNNode(geometry: label)
        // SCNText is generated at font-point scale, which is enormous in a
        // scene measured in metres.
        node.scale = SCNVector3(0.02, 0.02, 0.02)

        let (low, high) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((low.x + high.x) / 2, low.y, 0)
        node.position = SCNVector3(
            points.map(\.x).reduce(0, +) / CGFloat(points.count),
            (points.map(\.y).max() ?? 0) + boxPadding + 0.3,
            points.map(\.z).reduce(0, +) / CGFloat(points.count))
        // Always readable, whatever angle the rig is being viewed from.
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    // MARK: - Helpers

    private static func lineGeometry(points: [SCNVector3], indices: [Int32], color: NSColor) -> SCNGeometry {
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: points)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        geometry.materials = [overlayMaterial(color)]
        return geometry
    }

    /// Unlit and double-sided: these are annotations, so they should read at
    /// full strength wherever they sit rather than being shaded by the
    /// scene's lighting like real geometry.
    ///
    /// Depth testing is off in both directions, which makes the overlay an
    /// x-ray: an arrow on the far side of a truss still shows through it.
    /// That's deliberate — the whole job here is reading the numbering
    /// order, and half of it being hidden behind the rig defeats that.
    private static func overlayMaterial(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        return material
    }

    /// Axis-angle rotation taking a cone's default +Y axis onto `direction`.
    private static func rotationAligningUp(with direction: SCNVector3, length: CGFloat) -> SCNVector4 {
        let unit = SCNVector3(direction.x / length, direction.y / length, direction.z / length)
        let dot = max(-1, min(1, unit.y))

        // Already pointing along +Y, or exactly opposite — the cross product
        // is degenerate there, so pick an axis by hand.
        if dot > 0.9999 { return SCNVector4(1, 0, 0, 0) }
        if dot < -0.9999 { return SCNVector4(1, 0, 0, CGFloat.pi) }

        // cross((0,1,0), unit)
        let axis = SCNVector3(unit.z, 0, -unit.x)
        let axisLength = (axis.x * axis.x + axis.z * axis.z).squareRoot()
        guard axisLength > 0 else { return SCNVector4(1, 0, 0, 0) }
        return SCNVector4(axis.x / axisLength, 0, axis.z / axisLength, acos(dot))
    }
}
