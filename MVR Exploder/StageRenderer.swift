import AppKit
import SceneKit
import Metal

/// The rig as a picture: the 3D viewer's own scene, rendered offscreen.
///
/// Built by the same code the viewer uses — the same fixture models, the
/// same colours per type, the same lighting — with the venue's scene
/// geometry added. Built once, then aimed and rendered as often as
/// needed: the patch PDF's settings show a live preview, and rebuilding
/// the scene for every nudge of a slider would take a second each time on
/// a real rig.
final class StageScene {

    /// How the picture is taken: where the camera is, and what's in shot.
    struct Shot: Equatable {
        /// Round the rig, in degrees. 0 is from the front — the audience's
        /// side — negative round to the left, positive to the right, and
        /// ±180 from behind.
        var azimuth: Double = 0
        /// Above the rig, in degrees. 0 is eye level, 85 nearly straight
        /// down.
        var elevation: Double = 30
        /// 1 fits the rig to the frame; more is closer.
        var zoom: Double = 1
        /// Layers left out, by lowercased uuid.
        var hiddenLayers: Set<String> = []
        /// Whether the picture is the lighting fixtures alone, with none of
        /// the scene geometry — no stage, truss, set or venue.
        var fixturesOnly = false

        static let front = Shot()
    }

    /// A layer that can be left out of the picture.
    struct Layer: Identifiable, Hashable {
        /// The layer's uuid, lowercased.
        let id: String
        let name: String
        let fixtureCount: Int
        let objectCount: Int
    }

    /// Every layer holding fixtures or scene geometry — the same list the
    /// 3D viewer's layer panel shows.
    let layers: [Layer]

    private let scene: SCNScene
    private let cameraNode: SCNNode
    private let floorNode: SCNNode
    private let geometry: SCNNode?
    /// Each fixture's node and the layer it's in.
    private let fixtureNodes: [(node: SCNNode, layer: String)]
    /// Where the rig is, ignoring the outliers.
    private let rig: (min: SCNVector3, max: SCNVector3)
    private let renderer: SCNRenderer

    /// Builds the scene. Nil when there is nothing positioned to show, or
    /// no GPU to render with.
    init?(document: MVRDocument, geometry loaded: MVRSceneGeometryLoader.LoadedGeometry?) {
        let fixtures = document.fixtures
        guard fixtures.contains(where: { $0.position3D != nil }),
              let device = MTLCreateSystemDefaultDevice()
        else { return nil }

        let specs = Set(fixtures.map(\.gdtfSpec)).sorted()
        var colorIndex: [String: Int] = [:]
        for (index, spec) in specs.enumerated() { colorIndex[spec] = index }

        let built = Fixture3DView.buildScene(
            fixtures: fixtures,
            specColorIndex: colorIndex,
            specCount: specs.count,
            document: document,
            autoIDGroups: nil)

        // The fixtures as they really look, not the marker dots.
        var layerOfFixture: [String: String] = [:]
        for fixture in fixtures { layerOfFixture[fixture.id] = fixture.layerUUID.lowercased() }
        var nodes: [(SCNNode, String)] = []
        for node in built.markersNode.childNodes {
            for child in node.childNodes {
                switch child.name {
                case Fixture3DView.detailedNodeName: child.isHidden = false
                case Fixture3DView.bubbleNodeName: child.isHidden = true
                default: break
                }
            }
            nodes.append((node, layerOfFixture[node.name ?? ""] ?? ""))
        }
        fixtureNodes = nodes

        if let node = loaded?.node {
            built.scene.rootNode.addChildNode(node)
            geometry = node
        } else {
            geometry = nil
        }

        layers = Self.layers(fixtures: fixtures, geometry: loaded?.layers ?? [])
        rig = Self.bounds(of: built.markersNode.childNodes.map(\.position))

        let camera = SCNCamera()
        camera.fieldOfView = Self.fieldOfView
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 5000
        camera.screenSpaceAmbientOcclusionIntensity = 1.4
        camera.screenSpaceAmbientOcclusionRadius = 0.5
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        built.scene.rootNode.addChildNode(cameraNode)

        scene = built.scene
        self.cameraNode = cameraNode
        floorNode = built.floorNode
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = built.scene
        renderer.pointOfView = cameraNode
    }

    /// Takes the picture.
    func render(_ shot: Shot, size: CGSize) -> NSImage {
        // Committed before the snapshot, not left to the end of the run
        // loop: SceneKit renders what has been committed, so a move made
        // in the same pass as the snapshot showed up one picture late —
        // the preview always showed the angle before the one asked for,
        // which looked like a camera that wouldn't come back.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        apply(shot, aspect: size.width / size.height)
        SCNTransaction.commit()
        SCNTransaction.flush()
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    /// Loads the venue geometry, which is the slow part — real files run
    /// to thousands of objects — so it can be done off the main thread
    /// before the scene is built.
    nonisolated static func loadGeometry(for url: URL?) async -> MVRSceneGeometryLoader.LoadedGeometry? {
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) {
            MVRSceneGeometryLoader.buildGeometryNode(mvrURL: url)
        }.value
    }

    // MARK: - Aiming

    private static let fieldOfView: CGFloat = 50

    private func apply(_ shot: Shot, aspect: CGFloat) {
        for (node, layer) in fixtureNodes {
            node.isHidden = shot.hiddenLayers.contains(layer)
        }

        // The scene geometry in the layers that are shown, unless it's
        // fixtures only, and the floor dropped under all of it so the two
        // don't flicker through each other.
        var lowest: CGFloat?
        for (node, _) in fixtureNodes where !node.isHidden {
            lowest = min(lowest ?? node.position.y, node.position.y)
        }
        if let geometry {
            geometry.isHidden = shot.fixturesOnly
            for layer in geometry.childNodes {
                layer.isHidden = shot.hiddenLayers.contains((layer.name ?? "").lowercased())
                guard !shot.fixturesOnly, !layer.isHidden else { continue }
                for object in layer.childNodes {
                    lowest = min(lowest ?? .greatestFiniteMagnitude, Self.worldBox(of: object).min.y)
                }
            }
        }
        if let lowest { floorNode.position.y = lowest - 0.01 }

        aim(shot, aspect: aspect)
    }

    /// Fitted to the rig rather than the venue, which can be a whole arena
    /// with the rig a speck in the middle of it.
    private func aim(_ shot: Shot, aspect: CGFloat) {
        let azimuth = CGFloat(shot.azimuth * .pi / 180)
        let elevation = CGFloat(min(85, max(0, shot.elevation)) * .pi / 180)

        let center = SCNVector3(
            (rig.min.x + rig.max.x) / 2, (rig.min.y + rig.max.y) / 2, (rig.min.z + rig.max.z) / 2)
        let halfX = (rig.max.x - rig.min.x) / 2
        let halfY = (rig.max.y - rig.min.y) / 2
        let halfZ = (rig.max.z - rig.min.z) / 2

        // The rig's extent across the frame and along the view, from
        // wherever round it the camera is — from the side, its depth is
        // its width.
        let across = halfX * abs(cos(azimuth)) + halfZ * abs(sin(azimuth))
        let along = halfX * abs(sin(azimuth)) + halfZ * abs(cos(azimuth))
        // A metre of room round the outside, so fixtures at the edge
        // aren't cut by the frame.
        let halfWidth = across + 1
        let halfHeight = max(halfY * cos(elevation), along * sin(elevation)) + 1

        let verticalHalf = Self.fieldOfView / 2 * .pi / 180
        let horizontalHalf = atan(tan(verticalHalf) * aspect)
        let fitted = max(halfWidth / tan(horizontalHalf), halfHeight / tan(verticalHalf)) * 1.08
            + along * cos(elevation)
        let distance = fitted / CGFloat(max(0.25, shot.zoom))

        cameraNode.position = SCNVector3(
            center.x + distance * cos(elevation) * sin(azimuth),
            center.y + distance * sin(elevation),
            center.z + distance * cos(elevation) * cos(azimuth))
        // Set outright from the two angles — tilt down, then turn round —
        // rather than by `look(at:)`, which works from wherever the camera
        // was already pointing: after a pass through the top view it kept
        // a roll that no later shot took out, so Reset showed the front of
        // the rig tipped on its side.
        cameraNode.simdOrientation =
            simd_quatf(angle: Float(azimuth), axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: Float(-elevation), axis: SIMD3<Float>(1, 0, 0))
    }

    // MARK: - What's in shot

    /// Where the rig is, ignoring the few fixtures far from the rest of it.
    ///
    /// Taken between the 3rd and 97th percentile on each axis rather than
    /// from the extremes: a followspot at front of house or a fixture left
    /// at the origin is real, but framing the page to include it left the
    /// rig a small cluster in the middle of the picture.
    private static func bounds(of points: [SCNVector3]) -> (min: SCNVector3, max: SCNVector3) {
        func band(_ values: [CGFloat]) -> (CGFloat, CGFloat) {
            let sorted = values.sorted()
            guard let first = sorted.first, let last = sorted.last else { return (0, 0) }
            guard sorted.count >= 10 else { return (first, last) }
            let low = Int((Double(sorted.count - 1) * 0.03).rounded())
            let high = Int((Double(sorted.count - 1) * 0.97).rounded())
            return (sorted[low], sorted[high])
        }
        let (minX, maxX) = band(points.map(\.x))
        let (minY, maxY) = band(points.map(\.y))
        let (minZ, maxZ) = band(points.map(\.z))
        return (SCNVector3(minX, minY, minZ), SCNVector3(maxX, maxY, maxZ))
    }

    /// An object's bounding box in scene space, from its eight corners.
    private static func worldBox(of node: SCNNode) -> (min: SCNVector3, max: SCNVector3) {
        let (low, high) = node.boundingBox
        var minimum = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maximum = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for x in [low.x, high.x] {
            for y in [low.y, high.y] {
                for z in [low.z, high.z] {
                    let corner = node.convertPosition(SCNVector3(x, y, z), to: nil)
                    minimum = SCNVector3(min(minimum.x, corner.x), min(minimum.y, corner.y), min(minimum.z, corner.z))
                    maximum = SCNVector3(max(maximum.x, corner.x), max(maximum.y, corner.y), max(maximum.z, corner.z))
                }
            }
        }
        return (minimum, maximum)
    }

    /// Fixture layers and geometry layers merged by uuid, so a layer
    /// holding both appears once. Fixture layers first, in file order.
    private static func layers(
        fixtures: [MVRFixture], geometry: [MVRSceneGeometryLoader.SceneGeometryLayer]
    ) -> [Layer] {
        var names: [String: String] = [:]
        var fixtureCounts: [String: Int] = [:]
        var objectCounts: [String: Int] = [:]
        var order: [String] = []

        for fixture in fixtures {
            let key = fixture.layerUUID.lowercased()
            if names[key] == nil {
                names[key] = fixture.layerName.isEmpty ? "Ungrouped" : fixture.layerName
                order.append(key)
            }
            fixtureCounts[key, default: 0] += 1
        }
        for layer in geometry {
            let key = layer.uuid.lowercased()
            if names[key] == nil {
                names[key] = layer.name.isEmpty ? "Ungrouped" : layer.name
                order.append(key)
            }
            objectCounts[key] = layer.objectCount
        }
        return order.map {
            Layer(id: $0, name: names[$0] ?? "", fixtureCount: fixtureCounts[$0] ?? 0,
                  objectCount: objectCounts[$0] ?? 0)
        }
    }
}
