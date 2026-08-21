import SwiftUI
import SceneKit
import AppKit

/// A compact 3D view of fixture positions, built for checking an Auto ID
/// grouping and nothing else.
///
/// Deliberately not the full `Fixture3DView`: this shows fixtures as plain
/// markers rather than their real GDTF geometry, and skips scene geometry
/// entirely. Grouping is about *where fixtures are*, so the mesh loading
/// that dominates the real viewer would buy nothing here and would make
/// opening the sheet slow.
///
/// The scene is built once and then only updated — markers change colour
/// and visibility, the overlay is rebuilt, and the camera re-frames — so
/// clicking through types and groups stays immediate.
struct AutoIDPreviewView: NSViewRepresentable {
    let fixtures: [MVRFixture]
    /// Only this type's fixtures are shown; the rest fade back as context.
    let focusedSpec: String?
    let overlays: [AutoIDGroupOverlay]
    /// Group to frame the camera on, as an index into `overlays`.
    let focusedGroup: Int?
    /// Every selected group, kept filled so a multiple selection is
    /// readable in the view while it is being assembled.
    let selectedGroups: Set<Int>
    /// Changes whenever the plan behind `overlays` was recomputed.
    let revision: Int
    /// Incremented to replay the numbering order as a run of flashes.
    let playToken: Int
    /// While true, dragging draws a cut line across the view instead of
    /// orbiting.
    let isSplitting: Bool
    /// The two halves a drawn cut divides the focused group into.
    let onSplit: (Set<String>, Set<String>) -> Void
    /// The fixture under the cursor and where to put its card, in view
    /// coordinates. Reported up rather than drawn here: the card is a
    /// SwiftUI view laid over the representable, same as in the 3D viewer.
    var onHoverFixture: (String?, CGPoint) -> Void = { _, _ in }
    /// A fixture the user clicked, so the sheet can select its group.
    /// `extend` is set when the click should add to the selection rather
    /// than replace it.
    var onPickFixture: (String, Bool) -> Void = { _, _ in }
    /// A right-click on a fixture: its id, and where to put the menu in
    /// SwiftUI's top-left coordinates.
    var onRequestMenu: (String, CGPoint) -> Void = { _, _ in }
    /// Groups swept out with a Control-drag, to add to the selection.
    var onMarqueeGroups: (Set<Int>) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = OrbitSCNView()
        let coordinator = context.coordinator
        coordinator.build(fixtures: fixtures, in: view)
        view.onDrag = { [weak coordinator] dx, dy, isPan in
            coordinator?.drag(dx: dx, dy: dy, isPan: isPan)
        }
        view.onZoom = { [weak coordinator] delta in coordinator?.zoom(delta) }
        view.onSplitLine = { [weak coordinator] start, end in
            coordinator?.splitAcross(from: start, to: end)
        }
        view.onPick = { [weak coordinator] point, extend in
            guard let coordinator,
                  let fixtureID = coordinator.target(under: point)
            else { return }
            coordinator.reportPick(fixtureID, extend)
        }
        view.onRequestMenu = { [weak coordinator, weak view] point in
            guard let coordinator, let view,
                  let fixtureID = coordinator.target(under: point)
            else { return }
            coordinator.reportMenu(fixtureID, CGPoint(x: point.x, y: view.bounds.height - point.y))
        }
        view.onMarquee = { [weak coordinator] rect in
            coordinator?.reportMarquee(rect)
        }
        view.onHover = { [weak coordinator] point in
            guard let coordinator else { return }
            guard let point else {
                coordinator.highlight(nil)
                coordinator.fillGroup(under: nil)
                coordinator.reportHover(nil, .zero)
                return
            }
            // The box fills from anywhere inside it; the marker glow and
            // the card still need the cursor actually near a fixture.
            coordinator.fillGroup(under: point)
            let fixtureID = coordinator.fixture(under: point, radius: Coordinator.hoverRadius)
            coordinator.highlight(fixtureID)
            // Flipped into SwiftUI's top-left origin. SceneKit and AppKit
            // both work bottom-left here (see the note on hit testing in
            // Fixture3DView) but the card is positioned by SwiftUI.
            coordinator.reportHover(fixtureID, CGPoint(x: point.x, y: view.bounds.height - point.y))
        }
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        (nsView as? OrbitSCNView)?.splitMode = isSplitting
        context.coordinator.onSplit = onSplit
        context.coordinator.onHoverFixture = onHoverFixture
        context.coordinator.onPickFixture = onPickFixture
        context.coordinator.onRequestMenu = onRequestMenu
        context.coordinator.onMarqueeGroups = onMarqueeGroups
        context.coordinator.setSelected(selectedGroups)
        context.coordinator.update(
            focusedSpec: focusedSpec,
            overlays: overlays,
            focusedGroup: focusedGroup,
            revision: revision,
            playToken: playToken)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        private var scene = SCNScene()
        private let cameraNode = SCNNode()
        private let markersNode = SCNNode()
        private var overlayNode = SCNNode()

        private var markerBySpec: [String: [SCNNode]] = [:]
        private var positionsByFixture: [String: SCNVector3] = [:]

        private var yaw: CGFloat = 0
        private var pitch: CGFloat = atan(0.4)
        private var distance: CGFloat = 20
        private var target = SCNVector3Zero

        /// Reported when a drawn line cuts the focused group in two.
        var onSplit: ((Set<String>, Set<String>) -> Void)?
        var onHoverFixture: ((String?, CGPoint) -> Void)?
        var onPickFixture: ((String, Bool) -> Void)?
        var onRequestMenu: ((String, CGPoint) -> Void)?
        var onMarqueeGroups: ((Set<Int>) -> Void)?
        private var highlighted: String?

        /// How far from a marker a click still counts as hitting it. Wide,
        /// because clicking near a fixture plainly means that fixture.
        static let clickRadius: CGFloat = 18
        /// Much tighter for hover: a card that appears whenever the cursor
        /// is vaguely near something would never be off in a dense rig.
        static let hoverRadius: CGFloat = 6
        /// Padding around a group's projected fixtures, matching the drawn box.
        private let boxSlop: CGFloat = 10
        private var markerByFixture: [String: SCNNode] = [:]
        private var groupIndexByFixture: [String: Int] = [:]
        /// Fixture ids per group, in list order, for the screen-space box test.
        private var groupFixtures: [[String]] = []

        /// Screen positions of every targetable fixture, and the screen
        /// rectangle of every group, held between mouse moves.
        ///
        /// Both hit tests used to project every fixture on every single
        /// mouse-move: on a 307-fixture type that is ~600 `projectPoint`
        /// calls per event, and it showed. Projections only change when the
        /// camera moves, the view resizes or the plan changes, so they are
        /// computed once per change and scanned thereafter.
        private var projectedFixtures: [(id: String, point: CGPoint)] = []
        private var projectedGroups: [CGRect] = []
        private var projectionToken: ProjectionToken?
        private var overlayRevision = 0

        private struct ProjectionToken: Equatable {
            let camera: SCNVector3
            let size: CGSize
            let revision: Int

            static func == (a: ProjectionToken, b: ProjectionToken) -> Bool {
                a.revision == b.revision && a.size == b.size
                    && a.camera.x == b.camera.x && a.camera.y == b.camera.y && a.camera.z == b.camera.z
            }
        }
        private var selectedFills: Set<Int> = []
        private var hoveredFill: Int?
        /// Set when the selection came from clicking in this view.
        private var suppressNextFraming = false
        private weak var view: SCNView?
        private var focusedIDs: [String] = []

        private var lastPlayToken = 0
        private var lastSpec: String??
        private var lastGroup: Int??
        private var lastRevision: Int?

        func build(fixtures: [MVRFixture], in view: SCNView) {
            scene = SCNScene()
            scene.background.contents = NSColor(calibratedWhite: 0.08, alpha: 1)

            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 700
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)

            let key = SCNLight()
            key.type = .directional
            key.intensity = 600
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.eulerAngles = SCNVector3(-CGFloat.pi / 3, CGFloat.pi / 4, 0)
            scene.rootNode.addChildNode(keyNode)

            markersNode.name = "markers"
            scene.rootNode.addChildNode(markersNode)
            scene.rootNode.addChildNode(overlayNode)

            for fixture in fixtures {
                guard let position = fixture.position3D else { continue }
                let scenePosition = SCNVector3(
                    CGFloat(position.x / 1000),
                    CGFloat(position.z / 1000),
                    CGFloat(-position.y / 1000))

                let sphere = SCNSphere(radius: 0.14)
                sphere.segmentCount = 8
                sphere.firstMaterial?.lightingModel = .constant
                let node = SCNNode(geometry: sphere)
                node.position = scenePosition
                node.name = fixture.id

                markersNode.addChildNode(node)
                markerBySpec[fixture.gdtfSpec, default: []].append(node)
                markerByFixture[fixture.id] = node
                positionsByFixture[fixture.id] = scenePosition
            }

            cameraNode.camera = SCNCamera()
            cameraNode.camera?.zNear = 0.05
            cameraNode.camera?.zFar = 5000
            scene.rootNode.addChildNode(cameraNode)

            self.view = view
            view.scene = scene
            view.pointOfView = cameraNode
            view.antialiasingMode = .multisampling4X
            view.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)

            frame(on: Array(positionsByFixture.values), animated: false)
        }

        func update(
            focusedSpec: String?,
            overlays: [AutoIDGroupOverlay],
            focusedGroup: Int?,
            revision: Int,
            playToken: Int
        ) {
            let shouldPlay = playToken != lastPlayToken && playToken > 0
            lastPlayToken = playToken

            // Rebuilding the overlay and re-framing on every SwiftUI update
            // would fight the user's own camera moves, so this only runs when
            // something that actually matters has changed.
            let specChanged = lastSpec != .some(focusedSpec)
            let groupChanged = lastGroup != .some(focusedGroup)
            let planChanged = lastRevision != revision

            guard specChanged || groupChanged || planChanged else {
                if shouldPlay { play(order: flowOrder(overlays, focusedGroup)) }
                return
            }

            let isFirstUpdate = lastRevision == nil
            lastSpec = .some(focusedSpec)
            lastGroup = .some(focusedGroup)
            lastRevision = revision

            // Cancels any run still in flight, so a marker can't be left
            // stuck mid-flash when the selection moves on.
            resetFlashes()

            // Fixtures of other types stay visible but recede, so the one
            // being worked on reads clearly while keeping the rig's shape.
            for (spec, nodes) in markerBySpec {
                let isFocused = focusedSpec == nil || spec == focusedSpec
                for node in nodes {
                    node.isHidden = false
                    node.opacity = isFocused ? 1 : 0.12
                }
            }
            var colors: [String: NSColor] = [:]
            groupIndexByFixture = [:]
            groupFixtures = overlays.map(\.fixtureIDs)
            overlayRevision += 1
            for (index, overlay) in overlays.enumerated() {
                for id in overlay.fixtureIDs {
                    colors[id] = overlay.color
                    groupIndexByFixture[id] = index
                }
            }
            for nodes in markerBySpec.values {
                for node in nodes {
                    let color = node.name.flatMap { colors[$0] } ?? NSColor(calibratedWhite: 0.55, alpha: 1)
                    node.geometry?.firstMaterial?.diffuse.contents = color
                }
            }

            overlayNode.removeFromParentNode()
            hoveredFill = nil
            overlayNode = AutoIDOverlayBuilder.node(groups: overlays, positions: positionsByFixture)
            scene.rootNode.addChildNode(overlayNode)
            // The boxes are new nodes, so the fills have to be put back.
            refreshFills()

            // Frame the selected group, or the whole type when none is
            // picked. Driven by the *selection* changing, not by the plan
            // recomputing: a merge or split shouldn't throw away a camera
            // angle the user has just set up to inspect the result.
            let framingSuppressed = suppressNextFraming && !specChanged
            suppressNextFraming = false

            // Re-framing only for a single group. With several selected
            // `focusedGroup` is nil, and swinging the camera back to the
            // whole type on every addition fights the user mid-selection.
            if let focusedGroup, overlays.indices.contains(focusedGroup),
               groupChanged || specChanged, !framingSuppressed {
                frame(on: overlays[focusedGroup].fixtureIDs.compactMap { positionsByFixture[$0] }, animated: true)
            } else if specChanged || isFirstUpdate {
                let points = overlays.flatMap { $0.fixtureIDs }.compactMap { positionsByFixture[$0] }
                frame(on: points.isEmpty ? Array(positionsByFixture.values) : points, animated: !isFirstUpdate)
            }

            focusedIDs = flowOrder(overlays, focusedGroup)

            if shouldPlay { play(order: flowOrder(overlays, focusedGroup)) }
        }

        // MARK: - Hover

        func reportHover(_ fixtureID: String?, _ point: CGPoint) {
            onHoverFixture?(fixtureID, point)
        }

        func reportPick(_ fixtureID: String, _ extend: Bool) {
            // Picked in the view, so the camera stays put. Flying to a
            // group you are already looking at moves every other box for
            // the next half second, and a second click lands where a box
            // *was* rather than where it is — which reads as the click
            // simply doing nothing.
            suppressNextFraming = true
            onPickFixture?(fixtureID, extend)
        }

        func reportMenu(_ fixtureID: String, _ point: CGPoint) {
            suppressNextFraming = true
            onRequestMenu?(fixtureID, point)
        }

        /// The marker under the cursor, if any.
        ///
        /// Restricted to markers: the overlay's boxes and arrows are real
        /// geometry in the same scene and sit in front of the fixtures they
        /// annotate, so an unfiltered hit test would report the box far more
        /// often than the fixture.
        /// The fixture nearest the cursor, within a radius.
        ///
        /// Screen distance rather than a SceneKit ray cast. A marker is a
        /// 0.14m sphere — a handful of pixels at any sensible zoom — so
        /// asking someone to land on one exactly is asking them to miss;
        /// and a ray cast against every node on every mouse-move was a
        /// large part of what made a big type feel slow.
        func fixture(under point: CGPoint, radius: CGFloat) -> String? {
            nearestMarker(to: point, within: radius)
        }

        /// The group whose drawn box the cursor is inside.
        ///
        /// Hit-testing the fixtures alone made this nearly unusable: a
        /// marker is a few pixels across, and someone pointing at a group
        /// is pointing at the *box*, which is the thing they can see. The
        /// box is tested where it is drawn — in screen space — so it works
        /// from any angle without needing the 3D geometry to be hit.
        ///
        /// Overlapping boxes resolve to the smallest, which is the most
        /// specific thing under the cursor.
        func group(under point: CGPoint) -> Int? {
            refreshProjections()

            var best: (index: Int, area: CGFloat)?
            for (index, rect) in projectedGroups.enumerated() where rect.contains(point) {
                let area = rect.width * rect.height
                if best == nil || area < best!.area { best = (index, area) }
            }
            return best?.index
        }

        /// Rebuilds the screen-space caches, but only when something that
        /// moves them has actually changed.
        ///
        /// Keyed on the camera's *presentation* position, so an animated
        /// re-frame refreshes as it moves rather than leaving the cache
        /// stale until the next interaction. In an orbit camera every move
        /// — orbit, pan and zoom alike — changes that position, so it is a
        /// sufficient proxy for the whole transform.
        private func refreshProjections() {
            guard let view else { return }

            let token = ProjectionToken(
                camera: cameraNode.presentation.worldPosition,
                size: view.bounds.size,
                revision: overlayRevision)
            guard token != projectionToken else { return }
            projectionToken = token

            var points: [String: CGPoint] = [:]
            projectedFixtures.removeAll(keepingCapacity: true)
            for node in markersNode.childNodes {
                guard let name = node.name, !node.isHidden, isTargetable(name) else { continue }
                let projected = view.projectPoint(node.worldPosition)
                // Behind the camera, or beyond the far plane.
                guard projected.z > 0, projected.z < 1 else { continue }
                let point = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                projectedFixtures.append((name, point))
                points[name] = point
            }

            projectedGroups = groupFixtures.map { ids in
                var low = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
                var high = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)
                var any = false
                for id in ids {
                    guard let point = points[id] else { continue }
                    any = true
                    low.x = min(low.x, point.x); low.y = min(low.y, point.y)
                    high.x = max(high.x, point.x); high.y = max(high.y, point.y)
                }
                guard any else { return .null }
                // The drawn box is padded around its fixtures; so is this.
                return CGRect(x: low.x - boxSlop, y: low.y - boxSlop,
                              width: (high.x - low.x) + boxSlop * 2,
                              height: (high.y - low.y) + boxSlop * 2)
            }
        }

        /// Every group whose drawn box the rectangle touches.
        ///
        /// Intersection rather than containment: sweeping a box that has to
        /// swallow a 50m truss whole is not a selection gesture anyone
        /// wants to perform.
        func groups(in rect: CGRect) -> Set<Int> {
            refreshProjections()
            var found: Set<Int> = []
            for (index, box) in projectedGroups.enumerated() where !box.isNull && box.intersects(rect) {
                found.insert(index)
            }
            return found
        }

        func reportMarquee(_ rect: CGRect) {
            suppressNextFraming = true
            onMarqueeGroups?(groups(in: rect))
        }

        /// A fixture id standing for whatever is under the cursor: the
        /// nearest marker if there is one close, otherwise any member of
        /// the group whose box it is inside.
        func target(under point: CGPoint) -> String? {
            if let exact = fixture(under: point, radius: Coordinator.clickRadius) { return exact }
            guard let index = group(under: point) else { return nil }
            return groupFixtures[index].first
        }

        /// Whether a fixture can be picked at all.
        ///
        /// Only the type being worked on. The other types are drawn faded
        /// as context — they show the shape of the rig — but they are not
        /// something to hit: clicking one by accident used to throw you
        /// into a different type mid-job.
        private func isTargetable(_ fixtureID: String) -> Bool {
            groupIndexByFixture[fixtureID] != nil
        }

        /// The closest marker within a comfortable radius of a screen point.
        private func nearestMarker(to point: CGPoint, within radius: CGFloat) -> String? {
            refreshProjections()

            var best: (name: String, distance: CGFloat)?
            for entry in projectedFixtures {
                let distance = hypot(entry.point.x - point.x, entry.point.y - point.y)
                guard distance <= radius else { continue }
                if best == nil || distance < best!.distance { best = (entry.id, distance) }
            }
            return best?.name
        }

        /// Lights the hovered marker up and pops its scale, so the fixture
        /// under the cursor is unmistakable even when the card lands away
        /// from it at the edge of the view.
        ///
        /// Uses `emission` and scale — exactly the two things the flash
        /// animation drives — so the two can't leave each other in a half
        /// state, and `resetFlashes` clears a stale glow on its way past.
        func highlight(_ fixtureID: String?) {
            guard fixtureID != highlighted else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.12
            if let previous = highlighted, let node = markerByFixture[previous] {
                node.geometry?.firstMaterial?.emission.contents = NSColor.black
                node.scale = SCNVector3(1, 1, 1)
            }
            if let fixtureID, let node = markerByFixture[fixtureID] {
                node.geometry?.firstMaterial?.emission.contents = NSColor.white
                node.scale = SCNVector3(1.8, 1.8, 1.8)
            }
            SCNTransaction.commit()

            highlighted = fixtureID
        }

        /// Faces the hovered group's box, so which one you are pointing at
        /// is unmistakable among a dozen overlapping wireframes.
        private func solidNode(_ group: Int) -> SCNNode? {
            overlayNode.childNode(
                withName: "\(AutoIDOverlayBuilder.groupNodePrefix)\(group)", recursively: false)?
                .childNode(withName: AutoIDOverlayBuilder.solidNodeName, recursively: false)
        }

        /// Which groups are filled, and how strongly.
        ///
        /// A selected group stays filled for as long as it is selected —
        /// that is what makes assembling a multiple selection for a merge
        /// readable in the view. Hover is the same fill at a lower opacity,
        /// so the two never look alike.
        private func refreshFills() {
            for index in groupFixtures.indices {
                guard let solid = solidNode(index) else { continue }
                let isSelected = selectedFills.contains(index)
                let isHovered = hoveredFill == index
                solid.isHidden = !(isSelected || isHovered)
                solid.opacity = isSelected ? 1.0 : 0.45
            }
        }

        func setSelected(_ groups: Set<Int>) {
            guard groups != selectedFills else { return }
            let added = groups.subtracting(selectedFills)
            selectedFills = groups
            refreshFills()
            // Only what was just added pulses, so picking a third group
            // doesn't re-flash the two already chosen.
            for index in added { pulse(index) }
        }

        func fillGroup(under point: CGPoint?) {
            let index = point.flatMap { group(under: $0) }
            guard index != hoveredFill else { return }
            hoveredFill = index
            refreshFills()
        }

        /// Two clear beats — a single slow fade was easy to miss entirely.
        private func pulse(_ index: Int) {
            guard let solid = solidNode(index) else { return }
            solid.removeAllActions()
            solid.isHidden = false

            let resting: CGFloat = selectedFills.contains(index) ? 1.0 : 0.45
            solid.runAction(.sequence([
                .fadeOpacity(to: 1.0, duration: 0.06),
                .fadeOpacity(to: 0.15, duration: 0.12),
                .fadeOpacity(to: 1.0, duration: 0.10),
                .fadeOpacity(to: 0.15, duration: 0.12),
                .fadeOpacity(to: resting, duration: 0.14),
                .run { [weak self] node in
                    node.isHidden = !(self?.selectedFills.contains(index) ?? false)
                        && self?.hoveredFill != index
                },
            ]))
        }

        /// Divides the focused group by which side of a drawn line each
        /// fixture falls on.
        ///
        /// Done in screen space on purpose: the split lands where it was
        /// drawn, whatever angle the rig is being viewed from, so a truss
        /// can be cut between two specific fixtures by eye rather than by
        /// guessing at a distance threshold. `projectPoint` and AppKit mouse
        /// coordinates share the same bottom-left origin here, so the two
        /// can be compared directly.
        func splitAcross(from start: CGPoint, to end: CGPoint) {
            guard let view, focusedIDs.count > 1 else { return }

            let line = CGPoint(x: end.x - start.x, y: end.y - start.y)
            guard line.x * line.x + line.y * line.y > 25 else { return }   // ignore a stray click

            var near: Set<String> = []
            var far: Set<String> = []
            for id in focusedIDs {
                guard let position = positionsByFixture[id] else { continue }
                let projected = view.projectPoint(position)
                let offset = CGPoint(x: CGFloat(projected.x) - start.x, y: CGFloat(projected.y) - start.y)
                // Sign of the 2D cross product: which side of the line.
                if line.x * offset.y - line.y * offset.x >= 0 { near.insert(id) } else { far.insert(id) }
            }

            guard !near.isEmpty, !far.isEmpty else { return }
            onSplit?(near, far)
        }

        /// The selected group's fixtures in numbering order, or the whole
        /// type's when no single group is picked.
        private func flowOrder(_ overlays: [AutoIDGroupOverlay], _ focusedGroup: Int?) -> [String] {
            if let focusedGroup, overlays.indices.contains(focusedGroup) {
                return overlays[focusedGroup].fixtureIDs
            }
            return overlays.flatMap(\.fixtureIDs)
        }

        // MARK: - Flow animation

        /// Flashes each fixture in turn, in numbering order.
        ///
        /// The drawn path shows the *route* the numbers take but not which
        /// end they start from or how fast they move through a cluster —
        /// watching them light up in sequence answers both at a glance.
        ///
        /// Each fixture swells and glows white, then settles back, with the
        /// step timed so a whole run lands in a few seconds whether it's 12
        /// fixtures or 240; without that, a large type would take half a
        /// minute to play through.
        /// How long a full run of the numbering order should take.
        private let playBudget = 4.0

        private func play(order: [String]) {
            guard !order.isEmpty else { return }

            // The 0.02s floor used to break the budget this line exists to
            // enforce: 307 fixtures ran for 6.1s, not 4, and re-ran on every
            // change while a big type was being adjusted. A lower floor
            // keeps the run to its four seconds.
            let step = min(0.14, max(0.006, playBudget / Double(order.count)))
            // Settle scales with the step, so a dense run has a dozen
            // fixtures fading at once rather than seventeen — each one is a
            // per-frame closure, and they are the cost of this animation.
            let settle = min(0.34, max(0.12, step * 12))

            let markers = Dictionary(
                markersNode.childNodes.compactMap { node in node.name.map { ($0, node) } },
                uniquingKeysWith: { first, _ in first })

            resetFlashes()

            for (index, id) in order.enumerated() {
                guard let node = markers[id] else { continue }
                let baseColor = node.geometry?.firstMaterial?.diffuse.contents as? NSColor ?? .white

                let rise = SCNAction.group([
                    .scale(to: 2.6, duration: 0.09),
                    .run { $0.geometry?.firstMaterial?.emission.contents = NSColor.white },
                ])
                // Fades back through the group's own colour, so the trail
                // left behind still reads as belonging to that group.
                let fade = SCNAction.group([
                    .scale(to: 1, duration: settle),
                    .customAction(duration: settle) { node, elapsed in
                        let remaining = max(0, 1 - Double(elapsed) / settle)
                        node.geometry?.firstMaterial?.emission.contents = baseColor.withAlphaComponent(remaining)
                    },
                ])

                node.runAction(.sequence([
                    .wait(duration: Double(index) * step),
                    rise,
                    fade,
                    .run { $0.geometry?.firstMaterial?.emission.contents = NSColor.black },
                ]))
            }
        }

        /// Stops any run in progress and puts the markers back, so a replay
        /// or a change of selection can't leave one stuck mid-flash.
        private func resetFlashes() {
            for node in markersNode.childNodes {
                node.removeAllActions()
                node.scale = SCNVector3(1, 1, 1)
                node.geometry?.firstMaterial?.emission.contents = NSColor.black
            }
        }

        // MARK: - Camera

        private func frame(on points: [SCNVector3], animated: Bool) {
            guard !points.isEmpty else { return }
            let xs = points.map(\.x), ys = points.map(\.y), zs = points.map(\.z)
            let low = SCNVector3(xs.min() ?? 0, ys.min() ?? 0, zs.min() ?? 0)
            let high = SCNVector3(xs.max() ?? 0, ys.max() ?? 0, zs.max() ?? 0)

            target = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
            let span = max(high.x - low.x, max(high.y - low.y, high.z - low.z))
            distance = max(span * 1.8, 2)

            apply(animated: animated)
        }

        func drag(dx: CGFloat, dy: CGFloat, isPan: Bool) {
            if isPan {
                let scale = distance * 0.0015
                let right = SCNVector3(cos(yaw), 0, -sin(yaw))
                let up = SCNVector3(-sin(yaw) * sin(pitch), cos(pitch), -cos(yaw) * sin(pitch))
                target = SCNVector3(
                    target.x - (right.x * dx - up.x * dy) * scale,
                    target.y - (right.y * dx - up.y * dy) * scale,
                    target.z - (right.z * dx - up.z * dy) * scale)
            } else {
                yaw -= dx * 0.01
                pitch = max(-.pi / 2, min(.pi / 2, pitch + dy * 0.01))
            }
            apply(animated: false)
        }

        func zoom(_ delta: CGFloat) {
            distance = min(max(distance * min(2, max(0.5, exp(-delta * 0.04))), 0.25), 5000)
            apply(animated: false)
        }

        /// Same formulation as the main viewer's orbit camera: position from
        /// spherical offset, orientation from Euler angles with roll pinned
        /// to zero so the horizon stays level at every angle.
        private func apply(animated: Bool) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.35 : 0
            cameraNode.position = SCNVector3(
                target.x + distance * cos(pitch) * sin(yaw),
                target.y + distance * sin(pitch),
                target.z + distance * cos(pitch) * cos(yaw))
            cameraNode.eulerAngles = SCNVector3(-pitch, yaw, 0)
            SCNTransaction.commit()
        }
    }
}

/// Minimal orbit input. Camera control is owned outright rather than using
/// `allowsCameraControl`, which is stateful and silently overrides
/// programmatic camera moves once the user has dragged — the auto-framing
/// here depends on those moves landing.
private final class OrbitSCNView: SCNView {
    var onDrag: ((CGFloat, CGFloat, Bool) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    /// Cursor position in view coordinates, or nil once it leaves.
    var onHover: ((CGPoint?) -> Void)?
    /// A click that wasn't a drag, in view coordinates, and whether it
    /// should add to the selection.
    var onPick: ((CGPoint, Bool) -> Void)?
    /// A right-click that wasn't a drag, in view coordinates.
    var onRequestMenu: ((CGPoint) -> Void)?
    /// A rectangle dragged out with the extend modifier held.
    var onMarquee: ((CGRect) -> Void)?
    /// Start and end of a cut drawn across the view, in view coordinates.
    var onSplitLine: ((CGPoint, CGPoint) -> Void)?

    /// While set, a drag draws a cut line rather than orbiting.
    var splitMode = false {
        didSet {
            guard splitMode != oldValue else { return }
            if !splitMode { clearLine() } else { onHover?(nil) }
            // A knife cursor would be ideal; crosshair is the closest stock
            // shape that reads as "draw here" rather than "drag to orbit".
            splitMode ? NSCursor.crosshair.push() : NSCursor.pop()
        }
    }

    private var dragStart: CGPoint?
    private var hoverTracking: NSTrackingArea?

    /// Rebuilt on every resize: a tracking area is fixed to the rect it was
    /// made with, so a stale one stops reporting over the part of the view
    /// that grew.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        // While a cut is being drawn the card would sit under the cursor
        // and over the line.
        guard !splitMode else { return }
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }
    private lazy var lineLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemOrange.cgColor
        layer.fillColor = nil
        layer.lineWidth = 2
        layer.lineDashPattern = [6, 4]
        return layer
    }()

    /// Where the press began, used to tell a click from an orbit drag.
    private var pressStart: CGPoint?
    /// Whether the extend modifier was down when the press started. Held
    /// because someone can release the key before the button, and the
    /// intent was set at the press.
    private var pressExtends = false
    /// Where a Control-drag began, while it is being dragged.
    private var marqueeStart: CGPoint?

    private lazy var marqueeLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.controlAccentColor.cgColor
        layer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        layer.lineWidth = 1
        layer.lineDashPattern = [4, 3]
        return layer
    }()
    /// How far the cursor may move and still count as a click.
    private let clickSlop: CGFloat = 4

    /// Never calls `super`.
    ///
    /// NSView's default handling turns a Control-click into a context-menu
    /// gesture and enters its own tracking loop, so `mouseUp` never ran and
    /// Control-click could not extend the selection. Nothing here needs the
    /// default anyway — orbiting is driven from `mouseDragged`.
    override func mouseDown(with event: NSEvent) {
        pressStart = convert(event.locationInWindow, from: nil)
        pressExtends = Self.extendsSelection(event)
        guard splitMode else { return }
        dragStart = pressStart
        if lineLayer.superlayer == nil { layer?.addSublayer(lineLayer) }
    }

    override func mouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)

        if let start = marqueeStart {
            marqueeStart = nil
            marqueeLayer.path = nil
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y))
            pressStart = nil
            onMarquee?(rect)
            return
        }

        if splitMode, let start = dragStart {
            dragStart = nil
            clearLine()
            onSplitLine?(start, end)
            return
        }
        // A press that barely moved is a click, not the end of an orbit.
        if let start = pressStart, hypot(end.x - start.x, end.y - start.y) < clickSlop {
            pressStart = nil
            onPick?(end, pressExtends || Self.extendsSelection(event))
            return
        }
        pressStart = nil
    }

    /// Right-press state, kept so a two-finger drag can still pan.
    private var rightPressStart: CGPoint?
    private var rightDidDrag = false

    /// Deliberately does **not** call `super`.
    ///
    /// Opening a menu on press swallows the two-finger drag that pans the
    /// view — the gesture never gets a chance to start. The menu is held
    /// back until the release proves it was a click and not a drag.
    override func rightMouseDown(with event: NSEvent) {
        guard !splitMode else { return super.rightMouseDown(with: event) }
        rightPressStart = convert(event.locationInWindow, from: nil)
        rightDidDrag = false
        pressExtends = Self.extendsSelection(event)
    }

    /// Reports the click rather than letting AppKit raise a context menu.
    ///
    /// SwiftUI's `.contextMenu` is attached above this view and only fires
    /// from the press it never receives; replaying the stored event later
    /// did not raise it either. Reporting the point and letting the sheet
    /// present its own menu there is the version that actually works.
    override func rightMouseUp(with event: NSEvent) {
        let dragged = rightDidDrag
        let start = rightPressStart
        rightPressStart = nil
        rightDidDrag = false

        guard !dragged, start != nil else { return }
        // Some setups deliver a Control-click as a right-click. Here that
        // modifier means "add to the selection", so it must not also raise
        // the menu.
        guard !(pressExtends || Self.extendsSelection(event)) else {
            onPick?(convert(event.locationInWindow, from: nil), true)
            return
        }
        onRequestMenu?(convert(event.locationInWindow, from: nil))
    }

    /// Control extends the selection.
    ///
    /// **Not Command**, which is already the pan modifier here (see
    /// `mouseDragged`) — binding it to both meant a Command-click with a
    /// pixel of jitter panned instead of selecting, and the two gestures
    /// fought every time.
    private static func extendsSelection(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.control)
    }

    override func mouseDragged(with event: NSEvent) {
        // Control-drag sweeps out a selection instead of orbiting — the
        // natural extension of Control-click adding one group.
        if pressExtends, !splitMode {
            if marqueeStart == nil {
                marqueeStart = pressStart
                if marqueeLayer.superlayer == nil { layer?.addSublayer(marqueeLayer) }
            }
            guard let start = marqueeStart else { return }
            let current = convert(event.locationInWindow, from: nil)
            let rect = CGRect(
                x: min(start.x, current.x), y: min(start.y, current.y),
                width: abs(current.x - start.x), height: abs(current.y - start.y))
            marqueeLayer.frame = bounds
            marqueeLayer.path = CGPath(rect: rect, transform: nil)
            return
        }
        if splitMode {
            guard let start = dragStart else { return }
            let current = convert(event.locationInWindow, from: nil)
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: current)
            lineLayer.frame = bounds
            lineLayer.path = path
            return
        }
        let isPan = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        onDrag?(event.deltaX, event.deltaY, isPan)
    }

    private func clearLine() {
        lineLayer.path = nil
    }

    override func rightMouseDragged(with event: NSEvent) {
        if let start = rightPressStart {
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) >= clickSlop { rightDidDrag = true }
        }
        onDrag?(event.deltaX, event.deltaY, true)
    }

    override func scrollWheel(with event: NSEvent) {
        onZoom?(event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(-event.magnification * 60)
    }
}
