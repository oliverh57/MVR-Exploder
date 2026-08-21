import SwiftUI
import SceneKit
import AppKit
import ZIPFoundation
import UniformTypeIdentifiers

/// A camera-facing direction, independent of projection mode — Perspective
/// vs. Orthographic is a separate toggle, so any direction can be viewed in
/// either projection rather than needing one preset per combination.
private enum CameraDirection: String, CaseIterable, Identifiable {
    case front = "Front"
    case back = "Back"
    case left = "Left"
    case right = "Right"
    case top = "Top"
    case bottom = "Bottom"

    var id: String { rawValue }

    var yaw: CGFloat {
        switch self {
        case .front, .top, .bottom: return 0
        case .back: return .pi
        case .left: return -.pi / 2
        case .right: return .pi / 2
        }
    }

    var pitch: CGFloat {
        switch self {
        case .front, .back, .left, .right: return 0
        case .top: return .pi / 2
        case .bottom: return -.pi / 2
        }
    }
}

/// SCNView subclass owning all mouse interaction itself: hover tracking
/// (for the fixture info card) plus drag-to-orbit / scroll-and-pinch-to-
/// zoom for the camera. Camera interaction is handled here rather than via
/// SceneKit's built-in `allowsCameraControl` because `SCNCameraController`
/// is stateful and persists across the view's lifetime — once the user has
/// dragged even once, it starts actively recomputing and reapplying its
/// own cached orbit state on top of anything set programmatically, which
/// silently breaks the preset buttons after the first manual interaction.
/// Owning the camera transform directly (driven by Fixture3DView's
/// orbit state) sidesteps that entirely, and also removes a second,
/// independent event-handling system that was intermittently competing
/// with the hover tracking below for the same mouse events.
///
/// This view deliberately keeps AppKit's default bottom-left origin (i.e.
/// it does NOT override `isFlipped`). SceneKit's `projectPoint` and
/// `hitTest` both work in that bottom-left space regardless of the view's
/// `isFlipped` setting, so flipping the view puts mouse coordinates in a
/// vertically mirrored space from the picking APIs they get compared
/// against — which silently makes hover select whichever fixture happens
/// to sit at the mirrored y position, or nothing at all. Keeping one
/// coordinate space here means the single flip needed to position the
/// SwiftUI hover card is done explicitly, at that one call site.
private final class HoverTrackingSCNView: SCNView {
    var onHover: ((CGPoint) -> Void)?
    var onExit: (() -> Void)?
    var onOrbitDrag: ((CGFloat, CGFloat) -> Void)?
    var onPanDrag: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    private var trackingArea: NSTrackingArea?
    /// Where the current left-press started, so a press that turns into an
    /// orbit drag isn't also reported as a click on mouse-up.
    private var pressOrigin: CGPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        pressOrigin = convert(event.locationInWindow, from: nil)
    }

    /// Treats a press that barely moved as a click. Without the distance
    /// test every orbit drag would also fire a selection click when the
    /// button came back up.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { pressOrigin = nil }
        guard let origin = pressOrigin else { return }
        let end = convert(event.locationInWindow, from: nil)
        if hypot(end.x - origin.x, end.y - origin.y) <= 4 {
            onClick?(end)
        }
    }

    /// Left-drag orbits; holding Shift or Command pans instead, matching
    /// the modifier conventions of most CAD and previz tools.
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
            onPanDrag?(event.deltaX, event.deltaY)
        } else {
            onOrbitDrag?(event.deltaX, event.deltaY)
        }
    }

    /// Right- and middle-drag always pan, so a mouse user never needs a
    /// modifier key.
    override func rightMouseDragged(with event: NSEvent) {
        onPanDrag?(event.deltaX, event.deltaY)
    }

    override func otherMouseDragged(with event: NSEvent) {
        onPanDrag?(event.deltaX, event.deltaY)
    }

    override func scrollWheel(with event: NSEvent) {
        onZoom?(event.scrollingDeltaY, convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        // Scaled down from the wheel's units to suit the exponential zoom
        // rate in handleZoom — a pinch reports magnification in fractions,
        // where a scroll reports whole units.
        onZoom?(-event.magnification * 60, convert(event.locationInWindow, from: nil))
    }
}

private struct SceneKitContainerView: NSViewRepresentable {
    let scene: SCNScene
    let cameraNode: SCNNode
    /// Hit-testing is scoped to this subtree (the fixture markers only) so
    /// the SCNFloor's infinite plane can't win the closest-hit race.
    let markersRoot: SCNNode
    let markerNodes: [String: SCNNode]
    let onViewReady: (SCNView) -> Void
    let onHoverFixture: (String?, CGPoint) -> Void
    let onOrbitDrag: (CGFloat, CGFloat) -> Void
    let onPanDrag: (CGFloat, CGFloat) -> Void
    let onZoom: (CGFloat, CGPoint) -> Void
    /// Reports a click as both what it hit: the fixture (picked exactly as
    /// hover does, so clicking matches what the hover card was showing) and
    /// the scene object, either of which may be nil. Both are reported
    /// rather than resolved here because which one wins depends on whether
    /// export-selection mode is on, which this view doesn't know about.
    let onClick: (_ fixtureID: String?, _ objectID: String?) -> Void

    func makeNSView(context: Context) -> SCNView {
        let view = HoverTrackingSCNView()
        view.scene = scene
        view.pointOfView = cameraNode
        view.autoenablesDefaultLighting = false
        view.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        // Multisampling costs little at these scene sizes and removes the
        // stair-stepping on truss/fixture edges that dominates the look of
        // a wireframe-ish rig view.
        view.antialiasingMode = .multisampling4X

        view.onHover = { [weak view] point in
            guard let view else { return }
            let fixtureID = Self.fixtureID(at: point, in: view, markersRoot: markersRoot, markerNodes: markerNodes)
            // The view uses AppKit's bottom-left origin so mouse coords
            // line up with projectPoint/hitTest; SwiftUI's overlay space is
            // top-left, so flip exactly once, here, for the card.
            let cardPoint = CGPoint(x: point.x, y: view.bounds.height - point.y)
            onHoverFixture(fixtureID, cardPoint)
        }
        view.onExit = {
            onHoverFixture(nil, .zero)
        }
        view.onOrbitDrag = onOrbitDrag
        view.onPanDrag = onPanDrag
        view.onZoom = onZoom
        view.onClick = { [weak view] point in
            guard let view else { return }
            onClick(
                Self.fixtureID(at: point, in: view, markersRoot: markersRoot, markerNodes: markerNodes),
                Self.sceneObjectID(at: point, in: view))
        }

        DispatchQueue.main.async {
            onViewReady(view)
        }
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    /// Two-stage pick, in both cases scoped to the fixture markers only.
    ///
    /// 1. A real 3D hit-test against the fixture's actual geometry, so
    ///    pointing anywhere on a fixture's body selects it — this matters
    ///    for physically large fixtures like pixel bars, whose far end can
    ///    sit well outside any screen-distance threshold measured from the
    ///    fixture's origin point.
    /// 2. If that misses, the nearest marker origin within a small screen
    ///    radius, so small or distant fixtures are still easy to catch
    ///    without pixel-perfect aim.
    private static func fixtureID(
        at point: CGPoint,
        in view: SCNView,
        markersRoot: SCNNode,
        markerNodes: [String: SCNNode]
    ) -> String? {
        let hits = view.hitTest(point, options: [.rootNode: markersRoot])
        if let hit = hits.first, let id = fixtureID(owning: hit.node, markerNodes: markerNodes) {
            return id
        }
        return nearestFixtureID(to: point, in: view, markerNodes: markerNodes)
    }

    /// Finds the scene object under a click. Hidden nodes are skipped by
    /// default, so objects on a hidden layer can't be picked. The hit lands
    /// on an individual mesh deep inside the object, so this walks up to
    /// the nearest ancestor tagged as a scene object.
    private static func sceneObjectID(at point: CGPoint, in view: SCNView) -> String? {
        let hits = view.hitTest(point, options: [:])
        for hit in hits {
            var current: SCNNode? = hit.node
            while let candidate = current {
                if let name = candidate.name,
                   name.hasPrefix(MVRSceneGeometryLoader.SceneGeometryObject.nodeNamePrefix) {
                    return name
                }
                current = candidate.parent
            }
        }
        return nil
    }

    /// A hit can land on any part of a fixture's GDTF mesh hierarchy
    /// (base/yoke/head), and only the fixture's root marker node carries
    /// the fixture id as its name — so walk up to find the owning marker.
    private static func fixtureID(owning node: SCNNode, markerNodes: [String: SCNNode]) -> String? {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name, markerNodes[name] != nil { return name }
            current = candidate.parent
        }
        return nil
    }

    /// Picks the fixture whose marker origin projects closest to the mouse
    /// point on screen. Used as the fallback stage above.
    private static func nearestFixtureID(
        to point: CGPoint,
        in view: SCNView,
        markerNodes: [String: SCNNode],
        maxScreenDistance: CGFloat = 26
    ) -> String? {
        var bestID: String?
        var bestDistance = maxScreenDistance

        for (id, node) in markerNodes {
            let projected = view.projectPoint(node.worldPosition)
            // z is normalized depth (0...1 in front of the camera); points
            // behind the camera or beyond the far plane aren't visible.
            guard projected.z >= 0, projected.z <= 1 else { continue }

            let dx = CGFloat(projected.x) - point.x
            let dy = CGFloat(projected.y) - point.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                bestID = id
            }
        }

        return bestID
    }
}

/// An orbit-able 3D view of the show: every fixture in place, drawn as its
/// real GDTF geometry (or as plain colour-coded marker spheres, toggleable),
/// plus the MVR's own set geometry. Colour coding by GDTF type matches the
/// Fixture ID Map.
struct Fixture3DView: View {
    let fixtures: [MVRFixture]
    let onClose: () -> Void
    /// Reports a clicked fixture by its `MVRFixture.id`, so the editor can
    /// reveal it in the table.
    let onSelectFixture: (String) -> Void
    /// Proposed Auto ID grouping to draw over the rig — fixtures take their
    /// group's colour, and each group gets a box and a numbering path. Nil
    /// leaves the normal fixture-type legend colouring alone.
    let autoIDGroups: [AutoIDGroupOverlay]?

    /// Source file, kept so scene geometry can be loaded from it on a
    /// background task rather than during init.
    private let mvrURL: URL?

    private func suggestedFileName(for format: MVRGeometryExport.Format) -> String {
        let base = mvrURL.map { $0.deletingPathExtension().lastPathComponent } ?? "Scene Geometry"
        return "\(base) Geometry.\(format.fileExtension)"
    }

    private let sortedSpecs: [String]
    private let specColorIndex: [String: Int]
    private let fixturesByNodeName: [String: MVRFixture]
    private let markerNodesByFixtureID: [String: SCNNode]
    private let markerColorsByFixtureID: [String: NSColor]
    private let positionedCount: Int
    private let scene: SCNScene
    private let cameraNode: SCNNode
    private let markersNode: SCNNode
    private let floorNode: SCNNode
    private let sceneCenter: SCNVector3
    private let sceneRadius: CGFloat

    @State private var scnView: SCNView?
    @State private var hoveredFixture: MVRFixture?
    @State private var hoverPoint: CGPoint = .zero

    // Camera state we own outright (see HoverTrackingSCNView's doc comment
    // for why this replaces SceneKit's built-in allowsCameraControl).
    // Spherical orbit around `orbitTarget`: yaw is rotation around the
    // world-up axis measured from +Z, pitch is elevation above the
    // horizontal plane, both in radians.
    @State private var orbitYaw: CGFloat
    @State private var orbitPitch: CGFloat
    @State private var orbitDistance: CGFloat
    @State private var orbitTarget: SCNVector3
    @State private var isOrthographic = false
    @State private var showCameraViewPopover = false

    /// Real GDTF meshes vs. plain marker spheres. Remembered between
    /// sessions — it's a working preference, not a per-file one.
    @AppStorage("showRealFixtureGeometry") private var showRealFixtureGeometry = true

    @State private var sceneGeometryNode: SCNNode?
    @State private var geometryLayers: [MVRSceneGeometryLoader.SceneGeometryLayer] = []
    @State private var geometryObjectNodes: [String: SCNNode] = [:]
    /// Object ids grouped by layer, and each object's layer — both derived
    /// once at load so the explorer never has to scan the full object list
    /// (which reaches ~6000) while rendering.
    @State private var objectIDsByLayer: [String: [String]] = [:]
    @State private var layerByObjectID: [String: String] = [:]
    /// Selected count per layer, maintained as selection changes so the
    /// per-layer tri-state control is O(1) to draw. The view body re-renders
    /// on every hover, so recounting here would be a real cost.
    @State private var selectedCountByLayer: [String: Int] = [:]
    @State private var hiddenLayerUUIDs: Set<String> = []

    // Export selection.
    @State private var isSelectingForExport = false
    @State private var selectedObjectIDs: Set<String> = []
    /// Objects in file order, so exported OBJ groups follow the MVR's own
    /// ordering rather than the unordered selection set.
    @State private var objectExportOrder: [(id: String, name: String)] = []
    @State private var exportMessage: String?
    @State private var exportFailed = false
    /// Objects whose geometry/materials have been copied off the shared
    /// cached meshes so they can be tinted individually.
    @State private var isolatedObjectIDs: Set<String> = []
    @State private var showSceneGeometry = true
    @State private var isLoadingGeometry = false
    @State private var hasAttemptedGeometryLoad = false

    init(
        fixtures: [MVRFixture],
        document: MVRDocument,
        autoIDGroups: [AutoIDGroupOverlay]? = nil,
        onClose: @escaping () -> Void,
        onSelectFixture: @escaping (String) -> Void
    ) {
        self.fixtures = fixtures
        self.onClose = onClose
        self.onSelectFixture = onSelectFixture
        self.autoIDGroups = autoIDGroups
        self.mvrURL = document.originalFileURL

        let specs = Set(fixtures.map(\.gdtfSpec)).sorted()
        self.sortedSpecs = specs
        var indexMap: [String: Int] = [:]
        for (index, spec) in specs.enumerated() {
            indexMap[spec] = index
        }
        self.specColorIndex = indexMap

        let built = Self.buildScene(
            fixtures: fixtures,
            specColorIndex: indexMap,
            specCount: specs.count,
            document: document,
            autoIDGroups: autoIDGroups)
        self.scene = built.scene
        self.cameraNode = built.cameraNode
        self.markersNode = built.markersNode
        self.floorNode = built.floorNode
        self.sceneCenter = built.center
        self.sceneRadius = built.radius
        self.positionedCount = built.positionedCount
        self.fixturesByNodeName = built.fixturesByNodeName
        self.markerNodesByFixtureID = built.markerNodesByFixtureID
        self.markerColorsByFixtureID = built.markerColorsByFixtureID

        // Matches the camera placement buildScene already gave cameraNode
        // (offset (0, 0.3d, d) from center, looking at center) so the
        // first frame renders identically to before this state took over.
        _orbitYaw = State(initialValue: 0)
        _orbitPitch = State(initialValue: atan(0.3))
        _orbitDistance = State(initialValue: max(built.radius * 1.6, 6) * CGFloat(1.09).squareRoot())
        _orbitTarget = State(initialValue: built.center)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sceneArea
                Divider()
                sceneExplorer
            }
            Divider()
            legend
        }
        // Flexible rather than fixed so the hosting window can be resized
        // and zoomed; the minimum keeps the header controls and explorer
        // usable.
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { applyFixtureRepresentation() }
        .task { await loadSceneGeometryIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("3D View")
                .font(.headline)

            Divider().frame(height: 20)

            Picker("Projection", selection: $isOrthographic) {
                Text("Perspective").tag(false)
                Text("Orthographic").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            // A subtle color difference between the two modes, beyond just
            // the segmented control's own selected-pill highlight.
            .tint(isOrthographic ? .orange : .blue)
            .onChange(of: isOrthographic) { _, _ in
                // Switches projection in place — direction and distance are
                // untouched, only how the camera projects them changes.
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.25
                applyCameraTransform()
                SCNTransaction.commit()
            }

            Picker("Fixtures", selection: $showRealFixtureGeometry) {
                Text("Real").tag(true)
                Text("Bubble").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("Draw fixtures as their real GDTF geometry, or as plain marker spheres.")
            .onChange(of: showRealFixtureGeometry) { _, _ in
                applyFixtureRepresentation()
            }

            Button {
                showCameraViewPopover = true
            } label: {
                Label("Camera View", systemImage: "video")
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showCameraViewPopover, arrowEdge: .bottom) {
                cameraViewPopover
            }

            Button("Fit All") { fitAll() }
                .buttonStyle(.bordered)

            if !isAutoIDPreview {
                Divider().frame(height: 20)

                Button {
                    isSelectingForExport.toggle()
                    // Selecting is impossible with the geometry hidden —
                    // clicks can't hit it — so turn it back on rather than
                    // leaving the mode looking broken.
                    if isSelectingForExport && !showSceneGeometry {
                        showSceneGeometry = true
                        applyLayerVisibility()
                    }
                } label: {
                    Label("Select Geometry for Export", systemImage: isSelectingForExport ? "cube.fill" : "cube")
                }
                .buttonStyle(.bordered)
                .tint(isSelectingForExport ? .accentColor : nil)
                .disabled(sceneGeometryNode == nil)
                .help(sceneGeometryNode == nil
                      ? "This MVR has no scene geometry to export."
                      : "Click objects in the view, or whole layers in the scene explorer, to mark them for export.")
                .fixedSize()
            }

            Spacer()

            if isLoadingGeometry {
                ProgressView()
                    .controlSize(.small)
                Text("Loading scene geometry…")
                    .foregroundStyle(.secondary)
            }
            Text("\(positionedCount) of \(fixtures.count) fixtures positioned")
                .foregroundStyle(.secondary)
            Button("Close", action: onClose)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// A view-cube-style 3x2 grid so opposite faces (Front/Back,
    /// Left/Right, Top/Bottom) line up as pairs, in whichever projection
    /// mode is currently selected.
    private var cameraViewPopover: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                cameraViewButton(.front)
                cameraViewButton(.back)
            }
            GridRow {
                cameraViewButton(.left)
                cameraViewButton(.right)
            }
            GridRow {
                cameraViewButton(.top)
                cameraViewButton(.bottom)
            }
        }
        .padding(10)
    }

    private func cameraViewButton(_ direction: CameraDirection) -> some View {
        Button(direction.rawValue) {
            moveCamera(to: direction)
            showCameraViewPopover = false
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scene explorer

    /// One toggleable entry in the scene explorer. Fixtures and scene
    /// geometry both hang off the same MVR `<Layer>`, so a layer row
    /// controls whichever of the two that layer actually contains.
    private struct ExplorerLayer: Identifiable {
        let id: String
        let name: String
        let fixtureCount: Int
        let objectCount: Int
    }

    /// Merges the layers seen on fixtures with those seen on scene
    /// geometry, keyed by layer uuid so a layer holding both kinds appears
    /// once. Fixture layers come first, in the order they appear in the
    /// file.
    private var explorerLayers: [ExplorerLayer] {
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
        for layer in geometryLayers {
            if names[layer.uuid] == nil {
                names[layer.uuid] = layer.name.isEmpty ? "Ungrouped" : layer.name
                order.append(layer.uuid)
            }
            objectCounts[layer.uuid] = layer.objectCount
        }

        return order.map {
            ExplorerLayer(
                id: $0,
                name: names[$0] ?? "Ungrouped",
                fixtureCount: fixtureCounts[$0] ?? 0,
                objectCount: objectCounts[$0] ?? 0)
        }
    }

    private var sceneExplorer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scene Explorer")
                    .font(.headline)
                Spacer()
                if !explorerLayers.isEmpty {
                    Button(hiddenLayerUUIDs.isEmpty ? "None" : "All") {
                        hiddenLayerUUIDs = hiddenLayerUUIDs.isEmpty
                            ? Set(explorerLayers.map(\.id))
                            : []
                        applyLayerVisibility()
                    }
                    .buttonStyle(.link)
                    .help(hiddenLayerUUIDs.isEmpty ? "Hide every layer" : "Show every layer")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if isSelectingForExport {
                exportSelectionBanner
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(explorerLayers) { layer in
                        layerRow(for: layer)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Scene geometry", isOn: $showSceneGeometry)
                    .toggleStyle(.checkbox)
                    .disabled(sceneGeometryNode == nil)
                Text(sceneGeometryNode == nil
                     ? (isLoadingGeometry ? "Loading…" : "This file has no set geometry.")
                     : "Set, staging and video walls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 220)
    }

    // MARK: - Export selection

    /// Single point where selection state changes, so the per-layer counts
    /// can't drift out of step with the id set.
    private func setSelection(_ isSelected: Bool, forObject objectID: String) {
        let alreadySelected = selectedObjectIDs.contains(objectID)
        guard alreadySelected != isSelected else { return }

        if isSelected {
            selectedObjectIDs.insert(objectID)
        } else {
            selectedObjectIDs.remove(objectID)
        }
        if let layer = layerByObjectID[objectID] {
            selectedCountByLayer[layer, default: 0] += isSelected ? 1 : -1
        }
        applySelectionAppearance(objectID: objectID, isSelected: isSelected)
    }

    private func toggleSelection(objectID: String) {
        setSelection(!selectedObjectIDs.contains(objectID), forObject: objectID)
    }

    private func setSelection(_ isSelected: Bool, forLayer layerUUID: String) {
        for id in objectIDsByLayer[layerUUID] ?? [] {
            setSelection(isSelected, forObject: id)
        }
    }

    private func clearSelection() {
        for id in selectedObjectIDs {
            applySelectionAppearance(objectID: id, isSelected: false)
        }
        selectedObjectIDs.removeAll()
        selectedCountByLayer.removeAll()
    }

    /// Tints one object to show whether it's marked for export.
    ///
    /// Meshes are cached and cloned across objects, and `clone()` shares
    /// the underlying geometry and materials — so tinting naively would
    /// recolour every other object built from the same mesh. The first time
    /// an object is tinted its geometry and materials are copied so it owns
    /// them; after that only the colour changes.
    private func applySelectionAppearance(objectID: String, isSelected: Bool) {
        guard let node = geometryObjectNodes[objectID] else { return }

        if !isolatedObjectIDs.contains(objectID) {
            node.enumerateHierarchy { child, _ in
                guard let geometry = child.geometry else { return }
                let copied = geometry.copy() as! SCNGeometry
                copied.materials = geometry.materials.map { $0.copy() as! SCNMaterial }
                child.geometry = copied
            }
            isolatedObjectIDs.insert(objectID)
        }

        let diffuse = isSelected ? MVRSceneGeometryLoader.selectedColor : MVRSceneGeometryLoader.baseColor
        let emission = isSelected
            ? MVRSceneGeometryLoader.selectedColor.withAlphaComponent(0.45)
            : NSColor.black
        node.enumerateHierarchy { child, _ in
            guard let material = child.geometry?.firstMaterial else { return }
            material.diffuse.contents = diffuse
            material.emission.contents = emission
        }
    }

    private func selectionState(forLayer layerUUID: String) -> (selected: Int, total: Int) {
        (selectedCountByLayer[layerUUID] ?? 0, objectIDsByLayer[layerUUID]?.count ?? 0)
    }

    private var exportSelectionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cube.fill")
                    .foregroundStyle(Color(nsColor: MVRSceneGeometryLoader.selectedColor))
                Text("\(selectedObjectIDs.count) selected")
                    .font(.callout.weight(.medium))
                Spacer()
                if !selectedObjectIDs.isEmpty {
                    Button("Clear") { clearSelection() }
                        .buttonStyle(.link)
                }
            }
            Text("Click objects in the view, or click a layer to select all objects in that layer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A menu rather than one button per format: the choice is
            // which file to write, not three different actions, and three
            // buttons in a narrow sidebar would crowd out the selection
            // count above them.
            Menu {
                ForEach(MVRGeometryExport.Format.allCases) { format in
                    Button {
                        exportSelection(as: format)
                    } label: {
                        Text("\(format.label) (.\(format.fileExtension))")
                    }
                    .help(format.detail)
                }
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .disabled(selectedObjectIDs.isEmpty)

            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(exportFailed ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Asks for a destination, then writes the selected objects out. The
    /// selection is exported in the order the objects appear in the file so
    /// the exported groups line up with the MVR's own ordering.
    private func exportSelection(as format: MVRGeometryExport.Format) {
        let items = objectExportOrder
            .filter { selectedObjectIDs.contains($0.id) }
            .compactMap { entry -> MVRGeometryExport.ExportItem? in
                guard let node = geometryObjectNodes[entry.id] else { return nil }
                return MVRGeometryExport.ExportItem(node: node, name: entry.name)
            }
        guard !items.isEmpty else { return }

        let panel = NSSavePanel()
        panel.prepareForExport(
            named: suggestedFileName(for: format), fileExtension: format.fileExtension)
        panel.canCreateDirectories = true
        panel.title = "Export Selected Geometry"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // macOS has no registered type for .dxf, so the panel won't
            // append one — the file would land extensionless.
            let summary = try MVRGeometryExport.export(
                items: items, as: format, to: url.ensuringPathExtension(format.fileExtension))
            exportFailed = false
            exportMessage = "Exported \(summary.objectCount) object\(summary.objectCount == 1 ? "" : "s"), "
                + "\(summary.triangleCount.formatted()) triangles to \(format.label)."
        } catch {
            exportFailed = true
            exportMessage = error.localizedDescription
        }
    }

    /// One row in the scene explorer. Visibility (the checkbox) and export
    /// selection (clicking the layer itself) are deliberately separate
    /// gestures on separate parts of the row — an earlier version put a
    /// second tri-state checkbox next to the visibility one and that read
    /// as two competing checkboxes rather than "click to select this
    /// layer's objects".
    private func layerRow(for layer: ExplorerLayer) -> some View {
        let selection = selectionState(forLayer: layer.id)
        let isSelectable = isSelectingForExport && layer.objectCount > 0
        let isFullySelected = isSelectable && selection.selected == selection.total && selection.total > 0
        let isPartiallySelected = isSelectable && selection.selected > 0 && !isFullySelected

        return HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { !hiddenLayerUUIDs.contains(layer.id) },
                set: { isVisible in
                    if isVisible {
                        hiddenLayerUUIDs.remove(layer.id)
                    } else {
                        hiddenLayerUUIDs.insert(layer.id)
                    }
                    applyLayerVisibility()
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(layerSubtitle(for: layer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isFullySelected || isPartiallySelected {
                    Image(systemName: isFullySelected ? "checkmark.circle.fill" : "minus.circle.fill")
                        .foregroundStyle(Color(nsColor: MVRSceneGeometryLoader.selectedColor))
                        .font(.caption)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isFullySelected
                          ? Color(nsColor: MVRSceneGeometryLoader.selectedColor).opacity(0.35)
                          : isPartiallySelected
                          ? Color(nsColor: MVRSceneGeometryLoader.selectedColor).opacity(0.16)
                          : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard isSelectable else { return }
                setSelection(selection.selected < selection.total, forLayer: layer.id)
            }
            .onHover { hovering in
                guard isSelectable else { return }
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(isSelectable
                  ? "Select this layer's \(layer.objectCount) object\(layer.objectCount == 1 ? "" : "s") for export"
                  : "")
        }
        .padding(.vertical, 2)
    }

    private func layerSubtitle(for layer: ExplorerLayer) -> String {
        var parts: [String] = []
        if layer.fixtureCount > 0 {
            parts.append("\(layer.fixtureCount) fixture\(layer.fixtureCount == 1 ? "" : "s")")
        }
        if layer.objectCount > 0 {
            parts.append("\(layer.objectCount) object\(layer.objectCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: ", ")
    }

    /// Pushes the current layer selection onto the scene. Fixture markers
    /// are matched by their own layer uuid; scene geometry layers are the
    /// named child nodes the loader groups objects under.
    private func applyLayerVisibility() {
        for fixture in fixtures {
            markerNodesByFixtureID[fixture.id]?.isHidden = hiddenLayerUUIDs.contains(fixture.layerUUID.lowercased())
        }
        if let geometryRoot = sceneGeometryNode {
            geometryRoot.isHidden = !showSceneGeometry
            for layerNode in geometryRoot.childNodes {
                layerNode.isHidden = hiddenLayerUUIDs.contains(layerNode.name ?? "")
            }
        }
        // A hovered fixture that just got hidden shouldn't keep its card up.
        if let hovered = hoveredFixture, hiddenLayerUUIDs.contains(hovered.layerUUID.lowercased()) {
            setHighlighted(false, fixtureID: hovered.id)
            hoveredFixture = nil
        }
    }

    /// Parses the MVR's scene geometry once, off the main thread — real
    /// files reach several thousand objects and meshes, which would stall
    /// the UI for seconds if built during init like the fixture markers.
    private func loadSceneGeometryIfNeeded() async {
        guard !hasAttemptedGeometryLoad, let mvrURL else { return }
        hasAttemptedGeometryLoad = true
        isLoadingGeometry = true

        let loaded = await Task.detached(priority: .userInitiated) {
            MVRSceneGeometryLoader.buildGeometryNode(mvrURL: mvrURL)
        }.value

        isLoadingGeometry = false
        geometryLayers = loaded.layers

        var idsByLayer: [String: [String]] = [:]
        var layerByObject: [String: String] = [:]
        for object in loaded.objects {
            idsByLayer[object.layerUUID, default: []].append(object.id)
            layerByObject[object.id] = object.layerUUID
        }
        objectIDsByLayer = idsByLayer
        layerByObjectID = layerByObject
        objectExportOrder = loaded.objects.map { ($0.id, $0.name) }

        guard let node = loaded.node else { return }
        sceneGeometryNode = node

        var nodesByID: [String: SCNNode] = [:]
        for layerNode in node.childNodes {
            for objectNode in layerNode.childNodes {
                if let name = objectNode.name { nodesByID[name] = objectNode }
            }
        }
        geometryObjectNodes = nodesByID

        scene.rootNode.addChildNode(node)
        applyLayerVisibility()
        updateFloorPosition()
    }

    /// Rests the floor just under the lowest point of everything loaded —
    /// fixture positions and scene geometry alike, regardless of which
    /// layers are currently toggled on, so the floor doesn't jump around as
    /// layers are shown/hidden. Scene geometry (a stage, truss base, etc.)
    /// commonly sits at y=0 itself, which would otherwise coplane-flicker
    /// against a floor fixed at y=0.
    private func updateFloorPosition() {
        var minY: CGFloat?
        for node in markersNode.childNodes {
            minY = min(minY ?? node.position.y, node.position.y)
        }
        if let geometry = sceneGeometryNode {
            for layerNode in geometry.childNodes {
                let (low, _) = layerNode.boundingBox
                minY = min(minY ?? low.y, low.y)
            }
        }
        guard let minY else { return }
        floorNode.position.y = minY - 0.01
    }

    private var sceneArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                SceneKitContainerView(
                    scene: scene,
                    cameraNode: cameraNode,
                    markersRoot: markersNode,
                    markerNodes: markerNodesByFixtureID,
                    onViewReady: { scnView = $0 },
                    onHoverFixture: { fixtureID, point in
                        handleHover(fixtureID: fixtureID, at: point)
                    },
                    onOrbitDrag: { deltaX, deltaY in
                        handleOrbitDrag(deltaX: deltaX, deltaY: deltaY)
                    },
                    onPanDrag: { deltaX, deltaY in
                        handlePanDrag(deltaX: deltaX, deltaY: deltaY)
                    },
                    onZoom: { deltaY, point in
                        handleZoom(deltaY: deltaY, at: point)
                    },
                    onClick: { fixtureID, objectID in
                        // Export selection owns the click while its mode is
                        // on — otherwise a fixture standing in front of the
                        // set piece being aimed at would steal it. Outside
                        // that mode, clicking a fixture reveals it in the
                        // table, and clicking geometry does nothing, so
                        // ordinary orbiting never changes anything.
                        if isSelectingForExport {
                            guard let objectID else { return }
                            toggleSelection(objectID: objectID)
                        } else if let fixtureID {
                            onSelectFixture(fixtureID)
                        }
                    }
                )
                .onChange(of: showSceneGeometry) { _, _ in
                    applyLayerVisibility()
                }

                if let hoveredFixture {
                    hoverCard(for: hoveredFixture)
                        .position(
                            x: min(hoverPoint.x + 150, geo.size.width - 110),
                            y: min(hoverPoint.y + 80, geo.size.height - 80)
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func hoverCard(for fixture: MVRFixture) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fixture.name)
                .font(.headline)
            Text(fixture.gdtfSpec)
                .font(.caption)
                .foregroundStyle(.secondary)
            if fixture.mode != "-" {
                Text("Mode: \(fixture.mode)")
                    .font(.caption)
            }
            Text("Fixture ID: \(fixture.currentFixtureID.map(String.init) ?? "-")")
                .font(.caption)
            Text("Patch: Universe \(fixture.universe) / Channel \(fixture.channel)")
                .font(.caption)
            if !fixture.layerName.isEmpty {
                Text("Layer: \(fixture.layerName)")
                    .font(.caption)
            }
        }
        .padding(10)
        .background(.regularMaterial.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6)
        .frame(width: 220, alignment: .leading)
    }

    /// Updates the hovered fixture and, only on an actual change of target,
    /// swaps the glow highlight from the old marker to the new one.
    private func handleHover(fixtureID: String?, at point: CGPoint) {
        let newFixture = fixtureID.flatMap { fixturesByNodeName[$0] }
        if newFixture?.id != hoveredFixture?.id {
            setHighlighted(false, fixtureID: hoveredFixture?.id)
            setHighlighted(true, fixtureID: newFixture?.id)
            hoveredFixture = newFixture
        }
        hoverPoint = point
    }

    /// Lights a marker up bright white (not just a brightened version of
    /// its own legend color, which can be too close to the scene's ambient
    /// tones to read clearly) and pops its scale up sharply, so the
    /// fixture under the cursor is unmistakable at a glance — independent
    /// of the hover card, which can land far from the marker at the edges
    /// of the view.
    private func setHighlighted(_ isHighlighted: Bool, fixtureID: String?) {
        guard let fixtureID, let node = markerNodesByFixtureID[fixtureID] else { return }
        let baseColor = markerColorsByFixtureID[fixtureID] ?? .white

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.12
        // Real GDTF meshes are multi-part (base/yoke/head), so every part
        // under this fixture's root needs the glow, not just one material.
        node.enumerateHierarchy { child, _ in
            child.geometry?.firstMaterial?.emission.contents = isHighlighted ? NSColor.white : baseColor.withAlphaComponent(0.3)
        }
        node.scale = isHighlighted ? SCNVector3(1.8, 1.8, 1.8) : SCNVector3(1, 1, 1)
        SCNTransaction.commit()
    }

    @ViewBuilder
    private var legend: some View {
        if isAutoIDPreview {
            autoIDLegend
        } else {
            fixtureTypeLegend
        }
    }

    /// Colours mean groups while previewing, so the per-type legend is
    /// replaced by a note on how to read the overlay.
    private var autoIDLegend: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .foregroundStyle(.secondary)
            Text("Smart Auto ID preview")
                .font(.callout.weight(.medium))
            Text("Each box is one group. The line and arrows run in the order IDs are assigned, starting at the dot.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(autoIDGroups?.count ?? 0) groups")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var fixtureTypeLegend: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(sortedSpecs, id: \.self) { spec in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: spec))
                            .frame(width: 14, height: 14)
                        Text(spec)
                            .font(.caption)
                    }
                }
            }
            .padding(12)
        }
    }

    private func color(for spec: String) -> Color {
        guard let index = specColorIndex[spec], !sortedSpecs.isEmpty else { return .gray }
        let hue = Double(index) / Double(sortedSpecs.count)
        return Color(hue: hue, saturation: 0.65, brightness: 0.85)
    }

    /// Jumps the orbit state to a named direction, animated, keeping
    /// whichever projection mode is currently selected. Because we own the
    /// camera transform outright (see HoverTrackingSCNView's doc comment),
    /// this can never be silently overridden by anything else — unlike the
    /// previous allowsCameraControl-based approach, this keeps working
    /// after the user has manually dragged the view.
    private func moveCamera(to direction: CameraDirection) {
        // Presets frame everything currently visible rather than the
        // fixture-only bounds captured at init — with set geometry loaded
        // the rig is often a small part of the scene, and a preset that
        // ignored it would drop you inside the venue model.
        frameVisibleScene()

        orbitYaw = direction.yaw
        orbitPitch = direction.pitch

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        applyCameraTransform()
        SCNTransaction.commit()
    }

    /// Recomputes cameraNode's position/orientation from the current orbit
    /// state (target/yaw/pitch/distance) and applies the orthographic
    /// scale to match — the single source of truth for the camera
    /// transform, called after any preset click or drag/zoom gesture.
    ///
    /// The orientation is built directly from yaw/pitch as Euler angles
    /// with roll pinned to zero, rather than via `look(at:)`. `look(at:)`
    /// *derives* an orientation and so can only ever be as well-conditioned
    /// as the geometry it's given, whereas assigning Euler angles makes a
    /// level horizon true by construction at every angle, including exactly
    /// at the poles — which is why the presets no longer need to stop a
    /// hair short of vertical to stay well-defined.
    private func applyCameraTransform() {
        guard let camera = cameraNode.camera else { return }

        let x = orbitTarget.x + orbitDistance * cos(orbitPitch) * sin(orbitYaw)
        let y = orbitTarget.y + orbitDistance * sin(orbitPitch)
        let z = orbitTarget.z + orbitDistance * cos(orbitPitch) * cos(orbitYaw)
        cameraNode.position = SCNVector3(x, y, z)
        cameraNode.eulerAngles = SCNVector3(-orbitPitch, orbitYaw, 0)

        // Tracks the orbit distance instead of sitting at SceneKit's default
        // of 1.0, which quietly clipped away anything within a metre of the
        // camera — so even once the orbit was allowed closer, a fixture
        // being leaned into simply vanished. Scaling it keeps depth-buffer
        // precision reasonable when pulled back across a whole venue.
        camera.zNear = max(0.02, Double(orbitDistance) * 0.002)

        camera.usesOrthographicProjection = isOrthographic
        if isOrthographic {
            camera.orthographicScale = Double(orbitDistance) * 0.6
        }
    }

    /// Drag-to-orbit: horizontal movement rotates around the target,
    /// vertical movement changes elevation. Pitch is clamped upright so the
    /// view can't tumble over the top; yaw is normalised into (-pi, pi] so
    /// it can't wind up after repeated dragging — otherwise a later preset
    /// would animate the long way round through several full spins to reach
    /// the same facing.
    private func handleOrbitDrag(deltaX: CGFloat, deltaY: CGFloat) {
        let sensitivity: CGFloat = 0.01
        orbitYaw = Self.normalizedAngle(orbitYaw - deltaX * sensitivity)
        orbitPitch = min(.pi / 2, max(-.pi / 2, orbitPitch + deltaY * sensitivity))
        applyCameraTransform()
    }

    /// Wraps an angle into (-pi, pi].
    private static func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        let twoPi = 2 * CGFloat.pi
        var wrapped = angle.truncatingRemainder(dividingBy: twoPi)
        if wrapped <= -.pi { wrapped += twoPi }
        if wrapped > .pi { wrapped -= twoPi }
        return wrapped
    }

    /// Pan: slides the orbit target across the camera's own view plane, so
    /// dragging moves the scene with the cursor at any orientation. Without
    /// this the target was pinned to the rig's centre, which made it
    /// impossible to inspect anything off to one side of a big plot.
    /// Distance-scaled so the apparent speed stays constant as you zoom.
    private func handlePanDrag(deltaX: CGFloat, deltaY: CGFloat) {
        let scale = orbitDistance * 0.0015
        // Camera basis for the current yaw/pitch: right is unaffected by
        // pitch, up is the remaining axis of the view plane.
        let right = SCNVector3(cos(orbitYaw), 0, -sin(orbitYaw))
        let up = SCNVector3(
            -sin(orbitPitch) * sin(orbitYaw),
            cos(orbitPitch),
            -sin(orbitPitch) * cos(orbitYaw))

        orbitTarget = SCNVector3(
            orbitTarget.x - (right.x * deltaX - up.x * deltaY) * scale,
            orbitTarget.y - (right.y * deltaX - up.y * deltaY) * scale,
            orbitTarget.z - (right.z * deltaX - up.z * deltaY) * scale)
        applyCameraTransform()
    }

    /// Scroll wheel and trackpad pinch both zoom, clamped so the camera
    /// can't cross through its own target or recede indefinitely.
    ///
    /// The target also drifts toward whatever is under the cursor as you
    /// zoom in, so you can point at a far corner of the rig and dive
    /// straight into it instead of having to zoom and then pan back to it.
    private func handleZoom(deltaY: CGFloat, at point: CGPoint) {
        // Exponential, so the rate is the same at any distance and zooming
        // in then back out lands exactly where it started. The old linear
        // 1%-per-unit rate was the real reason zooming "stopped": a festival
        // file spreads its delay towers over 115m, so Fit All starts 161m
        // out and reaching a fixture-sized 0.5m view took ~190 scroll
        // notches. It was never clamped, just asymptotically slow. Clamped
        // per event so trackpad momentum can't leap the whole range at once.
        let factor = min(2, max(0.5, exp(-deltaY * 0.04)))
        // Fixed rather than a fraction of the scene: tying it to scene size
        // meant a festival-scale plot stopped you metres short of a fixture
        // only 0.4m across, in exactly the files where it matters most.
        // Far enough out to stay outside the fixture being inspected — the
        // zoom target now lands on the surface under the cursor, so a much
        // smaller floor put the camera inside the thing you were looking at.
        // At 0.25m a 0.4m fixture already more than fills the frame.
        let minDistance: CGFloat = 0.25
        let maxDistance = max(sceneRadius * 20, 50)
        let newDistance = min(maxDistance, max(minDistance, orbitDistance * factor))

        if let cursorPoint = worldPoint(under: point), newDistance < orbitDistance {
            let pull = 1 - (newDistance / orbitDistance)
            orbitTarget = SCNVector3(
                orbitTarget.x + (cursorPoint.x - orbitTarget.x) * pull,
                orbitTarget.y + (cursorPoint.y - orbitTarget.y) * pull,
                orbitTarget.z + (cursorPoint.z - orbitTarget.z) * pull)
        }

        orbitDistance = newDistance
        applyCameraTransform()
    }

    /// What the cursor is actually pointing at, in world space.
    ///
    /// Uses the real surface under the cursor, falling back to the plane
    /// through the orbit target only when the cursor is over empty sky.
    /// The plane alone is right only for things sitting at the target's
    /// depth, which is precisely wrong in the case that matters: after
    /// framing a whole site the target lands on the centroid of everything,
    /// so aiming at the far-off delay towers zoomed in correctly while
    /// aiming at the stage — much nearer the camera — drifted the target
    /// onto a point nowhere near it, and the stage never got closer.
    private func worldPoint(under point: CGPoint) -> SCNVector3? {
        guard let scnView else { return nil }

        let hits = scnView.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true,
        ])
        if let hit = hits.first {
            return hit.worldCoordinates
        }

        let projectedTarget = scnView.projectPoint(orbitTarget)
        return scnView.unprojectPoint(SCNVector3(CGFloat(point.x), CGFloat(point.y), CGFloat(projectedTarget.z)))
    }

    /// Bounds of everything currently on screen: visible fixture markers
    /// plus visible scene geometry. Hidden layers are excluded, so framing
    /// follows what the scene explorer is actually showing.
    private func visibleBounds() -> (min: SCNVector3, max: SCNVector3)? {
        var minBound = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maxBound = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var found = false

        func absorb(_ low: SCNVector3, _ high: SCNVector3) {
            minBound = SCNVector3(min(minBound.x, low.x), min(minBound.y, low.y), min(minBound.z, low.z))
            maxBound = SCNVector3(max(maxBound.x, high.x), max(maxBound.y, high.y), max(maxBound.z, high.z))
            found = true
        }

        // markersNode and the geometry root both sit at identity, so their
        // children's local coordinates are already world coordinates.
        for node in markersNode.childNodes where !node.isHidden {
            absorb(node.position, node.position)
        }
        if showSceneGeometry, let geometry = sceneGeometryNode {
            for layerNode in geometry.childNodes where !layerNode.isHidden {
                let (low, high) = layerNode.boundingBox
                absorb(low, high)
            }
        }

        return found ? (minBound, maxBound) : nil
    }

    /// Points the orbit at the centre of everything visible and backs off
    /// far enough to frame it, leaving yaw/pitch untouched.
    private func frameVisibleScene() {
        guard let bounds = visibleBounds() else {
            orbitTarget = sceneCenter
            orbitDistance = max(sceneRadius * 1.6, 6)
            return
        }
        let span = max(bounds.max.x - bounds.min.x,
                       max(bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z))
        orbitTarget = SCNVector3(
            (bounds.min.x + bounds.max.x) / 2,
            (bounds.min.y + bounds.max.y) / 2,
            (bounds.min.z + bounds.max.z) / 2)
        orbitDistance = max(span * 1.4, 2)
    }

    private func fitAll() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        frameVisibleScene()
        applyCameraTransform()
        SCNTransaction.commit()
    }

    private static func gridTexture() -> NSImage {
        let size = 512
        let cell = 32
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor(calibratedWhite: 0.44, alpha: 1).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        var x = 0
        while x <= size {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: size))
            x += cell
        }
        var y = 0
        while y <= size {
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: size, y: y))
            y += cell
        }
        path.stroke()
        image.unlockFocus()
        return image
    }

    private static func buildScene(
        fixtures: [MVRFixture],
        specColorIndex: [String: Int],
        specCount: Int,
        document: MVRDocument,
        autoIDGroups: [AutoIDGroupOverlay]?
    ) -> (
        scene: SCNScene,
        cameraNode: SCNNode,
        markersNode: SCNNode,
        floorNode: SCNNode,
        center: SCNVector3,
        radius: CGFloat,
        positionedCount: Int,
        fixturesByNodeName: [String: MVRFixture],
        markerNodesByFixtureID: [String: SCNNode],
        markerColorsByFixtureID: [String: NSColor]
    ) {
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedWhite: 0.06, alpha: 1)

        // Fixtures take their proposed group's colour while previewing an
        // Auto ID run, so the grouping reads directly off the rig.
        var autoIDColors: [String: NSColor]?
        if let autoIDGroups {
            var colors: [String: NSColor] = [:]
            for group in autoIDGroups {
                for id in group.fixtureIDs { colors[id] = group.color }
            }
            autoIDColors = colors
        }
        var scenePositionsByFixture: [String: SCNVector3] = [:]

        let floor = SCNFloor()
        floor.reflectivity = 0
        let floorMaterial = floor.firstMaterial
        floorMaterial?.diffuse.contents = gridTexture()
        floorMaterial?.diffuse.wrapS = .repeat
        floorMaterial?.diffuse.wrapT = .repeat
        floorMaterial?.diffuse.contentsTransform = SCNMatrix4MakeScale(30, 30, 1)
        floorMaterial?.lightingModel = .lambert
        let floorNode = SCNNode(geometry: floor)
        floorNode.castsShadow = false
        scene.rootNode.addChildNode(floorNode)

        let markersNode = SCNNode()
        markersNode.name = "markers"
        scene.rootNode.addChildNode(markersNode)

        var scenePositions: [SCNVector3] = []
        var fixturesByNodeName: [String: MVRFixture] = [:]
        var markerNodesByFixtureID: [String: SCNNode] = [:]
        var markerColorsByFixtureID: [String: NSColor] = [:]

        // GDTF lookups involve re-opening the source zip, so results are
        // cached per spec — most rigs reuse the same handful of fixture
        // types across many instances. `template(for:)` gives back a
        // ready-to-clone node tree built from the fixture's real .3ds
        // geometry when one could be parsed; `envelope(for:)` is the
        // lighter aggregate-box fallback for when it couldn't.
        var envelopeCache: [String: GDTFEnvelope?] = [:]
        func envelope(for spec: String) -> GDTFEnvelope? {
            if let cached = envelopeCache[spec] { return cached }
            let result = document.gdtfFileData(forSpec: spec).flatMap(gdtfEnvelope(fromPackageData:))
            envelopeCache[spec] = result
            return result
        }

        var assemblyCache: [String: GDTFAssembly?] = [:]
        func assembly(for spec: String) -> GDTFAssembly? {
            if let cached = assemblyCache[spec] { return cached }
            let result = document.gdtfFileData(forSpec: spec).flatMap(GDTFAssemblyParser.parse(packageData:))
            assemblyCache[spec] = result
            return result
        }

        var templateCache: [String: SCNNode?] = [:]
        func template(for spec: String) -> SCNNode? {
            if let cached = templateCache[spec] { return cached }
            guard let assembly = assembly(for: spec) else {
                templateCache[spec] = .some(nil)
                return nil
            }
            let container = SCNNode()
            for root in assembly.roots {
                container.addChildNode(root.buildNode(
                    models: assembly.models,
                    meshes: assembly.meshes,
                    gltfMeshes: assembly.gltfMeshes))
            }
            pruneEmptyBranches(container)

            // Collapse the whole fixture to a single mesh. A pixel bar is
            // modelled as one mesh per pixel — 382 on a real ACME Pixel Line
            // — so a rig holding 202 of them would otherwise cost 77,000
            // draw calls for that one fixture type alone. Merging is safe
            // here because every part of a fixture shares one material, and
            // the fixture's own node (which carries its position, hover
            // highlight and id) is untouched a level above.
            let result: SCNNode?
            if let merged = SCNGeometryMerge.merged(tree: container) {
                let node = SCNNode(geometry: merged)
                result = node
            } else {
                result = nil
            }
            templateCache[spec] = .some(result)
            return result
        }

        for fixture in fixtures {
            guard let pos = fixture.position3D else { continue }
            let scenePos = SCNVector3(
                CGFloat(pos.x / 1000),
                CGFloat(pos.z / 1000),
                CGFloat(-pos.y / 1000)
            )
            scenePositions.append(scenePos)

            let index = specColorIndex[fixture.gdtfSpec] ?? 0
            let hue = specCount > 0 ? Double(index) / Double(specCount) : 0
            let nsColor = autoIDColors?[fixture.id]
                ?? NSColor(hue: hue, saturation: 0.65, brightness: 0.85, alpha: 1)

            // Both representations are built once and swapped by hiding one
            // or the other, rather than rebuilding the scene on every toggle
            // — a rebuild costs about a second on a large file, which is far
            // too slow for what should feel like flicking a switch.
            let detailed: SCNNode
            if let template = template(for: fixture.gdtfSpec) {
                // .clone() deep-copies the node hierarchy but shares
                // geometry/material objects with the template — copy both
                // per instance so this fixture's hover highlight can't leak
                // onto every other fixture of the same GDTF type.
                let instance = template.clone()
                instance.enumerateHierarchy { child, _ in
                    guard let geometry = child.geometry else { return }
                    let newGeometry = geometry.copy() as! SCNGeometry
                    newGeometry.materials = geometry.materials.map { $0.copy() as! SCNMaterial }
                    child.geometry = newGeometry
                }
                detailed = instance
            } else if let box = envelope(for: fixture.gdtfSpec) {
                let scnBox = SCNBox(width: CGFloat(box.width), height: CGFloat(box.height), length: CGFloat(box.length), chamferRadius: 0)
                scnBox.firstMaterial?.diffuse.contents = nsColor
                detailed = SCNNode(geometry: scnBox)
            } else {
                let sphere = SCNSphere(radius: Self.bubbleRadius)
                sphere.firstMaterial?.diffuse.contents = nsColor
                detailed = SCNNode(geometry: sphere)
            }
            // The fixture's own rotation — a moving light hung upside down
            // under a truss, a bar angled on a boom. Applied to the
            // representation rather than to the container, which carries
            // the position and the hover scale and is what picking and
            // framing work off. Multiplied in rather than assigned, so a
            // GDTF template that arrives with a transform of its own keeps
            // it.
            if let orientation = MVRSceneGeometryLoader.orientation(
                fromMatrixText: fixture.matrixText) {
                detailed.transform = SCNMatrix4Mult(detailed.transform, orientation)
            }
            detailed.name = Self.detailedNodeName

            let bubbleGeometry = SCNSphere(radius: Self.bubbleRadius)
            bubbleGeometry.firstMaterial?.diffuse.contents = nsColor
            let bubble = SCNNode(geometry: bubbleGeometry)
            bubble.name = Self.bubbleNodeName

            // The fixture's own node stays a plain container carrying the
            // id, position and hover scale, so picking, highlighting and
            // framing are all unaffected by which representation is showing.
            let node = SCNNode()
            node.addChildNode(detailed)
            node.addChildNode(bubble)

            node.position = scenePos
            node.castsShadow = true
            node.name = fixture.id
            // Tint every part with the fixture type's legend color as a
            // resting-state rim glow (setHighlighted brightens it further).
            node.enumerateHierarchy { child, _ in
                child.geometry?.firstMaterial?.emission.contents = nsColor.withAlphaComponent(0.3)
            }

            fixturesByNodeName[fixture.id] = fixture
            markerNodesByFixtureID[fixture.id] = node
            markerColorsByFixtureID[fixture.id] = nsColor
            markersNode.addChildNode(node)
            scenePositionsByFixture[fixture.id] = scenePos
        }

        if let autoIDGroups {
            scene.rootNode.addChildNode(
                AutoIDOverlayBuilder.node(groups: autoIDGroups, positions: scenePositionsByFixture))
        }

        let center: SCNVector3
        let radius: CGFloat
        if scenePositions.isEmpty {
            center = SCNVector3(0, 0, 0)
            radius = 6
        } else {
            let xs = scenePositions.map(\.x)
            let ys = scenePositions.map(\.y)
            let zs = scenePositions.map(\.z)
            // Rests the floor under the lowest fixture position rather than
            // always at world y=0 — a stage or truss placed at y=0 would
            // otherwise coplane-flicker against the floor plane. Scene
            // geometry (which loads later, asynchronously) refines this
            // further once it's available; see updateFloorPosition().
            floorNode.position.y = (ys.min() ?? 0) - 0.01
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            let minZ = zs.min() ?? 0, maxZ = zs.max() ?? 0
            center = SCNVector3((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
            let span = max(maxX - minX, max(maxY - minY, maxZ - minZ))
            radius = max(span / 2, 1)
        }

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 5000

        // Screen-space ambient occlusion darkens crevices and contact
        // points — truss junctions, where a fixture's yoke meets its base,
        // where set pieces meet the floor — which is most of what reads as
        // "flat" in an unshadowed CG scene. The SDK's own default radius
        // (5, i.e. 5 metres here) is tuned for room-scale contact shadows;
        // the geometry that actually benefits from AO in a rig — fixture
        // bodies, truss members — sits at 0.1-0.5m scale, so a 5m radius
        // would occlude broadly instead of picking out real contact points.
        cameraNode.camera?.screenSpaceAmbientOcclusionIntensity = 1.4
        cameraNode.camera?.screenSpaceAmbientOcclusionRadius = 0.5

        let distance = max(radius * 1.6, 6)
        cameraNode.position = SCNVector3(center.x, center.y + distance * 0.3, center.z + distance)
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)

        // A flat environment acts as image-based lighting for the
        // physically-based scene-geometry materials, which otherwise render
        // almost black where the directional light doesn't reach.
        scene.lightingEnvironment.contents = NSColor(calibratedWhite: 0.65, alpha: 1)
        scene.lightingEnvironment.intensity = 1.4

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 480
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Fill light opposite the key, so surfaces facing away from the key
        // read as shape rather than flat silhouette.
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 400
        fill.castsShadow = false
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(-CGFloat.pi / 4, -CGFloat.pi * 0.75, 0)
        scene.rootNode.addChildNode(fillNode)

        let directional = SCNLight()
        directional.type = .directional
        directional.intensity = 1150
        directional.castsShadow = true
        directional.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.55)
        directional.shadowRadius = 6
        directional.shadowMode = .deferred
        let directionalNode = SCNNode()
        directionalNode.light = directional
        directionalNode.eulerAngles = SCNVector3(-CGFloat.pi / 3, CGFloat.pi / 4, 0)
        scene.rootNode.addChildNode(directionalNode)

        return (scene, cameraNode, markersNode, floorNode, center, radius, scenePositions.count, fixturesByNodeName, markerNodesByFixtureID, markerColorsByFixtureID)
    }

    /// True while the window is showing an Auto ID grouping preview, which
    /// is a read-only look at proposed numbering — the geometry-export
    /// tools have nothing to do with that job, and the fixture-type legend
    /// would be actively wrong, since colours mean groups here.
    private var isAutoIDPreview: Bool { autoIDGroups != nil }

    /// Names of the two representations held under every fixture node, so
    /// the toggle can find them without walking geometry.
    private static let detailedNodeName = "fixtureDetailed"
    private static let bubbleNodeName = "fixtureBubble"

    /// Radius of a marker sphere, in metres. Deliberately fixed rather than
    /// scaled per fixture — abstracting away the real size is the whole
    /// point of bubble mode, and a consistent dot is easier to read across
    /// a rig mixing tiny pars with metre-long pixel bars.
    private static let bubbleRadius: CGFloat = 0.12

    /// Shows whichever fixture representation is currently selected.
    private func applyFixtureRepresentation() {
        for node in markersNode.childNodes {
            for child in node.childNodes {
                switch child.name {
                case Self.detailedNodeName: child.isHidden = !showRealFixtureGeometry
                case Self.bubbleNodeName: child.isHidden = showRealFixtureGeometry
                default: break
                }
            }
        }
    }

    /// Strips branches of a built GDTF assembly that contain no geometry
    /// anywhere, returning whether anything drawable survived.
    ///
    /// A GDTF geometry tree carries a node per kinematic part, beam, emitter
    /// and mounting point, and most of those reference "Dummy" placeholder
    /// models that produce nothing to draw — one real fixture arrives as 69
    /// nodes holding 3 drawable meshes. Empty branches still cost scene-graph
    /// traversal on every frame, multiplied by every fixture in the rig, so
    /// they're dropped once per fixture type as the template is cached.
    /// Only wholly geometry-free subtrees go: a node with no geometry of its
    /// own is kept when it positions drawable children.
    @discardableResult
    private static func pruneEmptyBranches(_ node: SCNNode) -> Bool {
        var keep = node.geometry != nil
        // `childNodes` hands back a copy, so removing while iterating is safe.
        for child in node.childNodes {
            if pruneEmptyBranches(child) {
                keep = true
            } else {
                child.removeFromParentNode()
            }
        }
        return keep
    }

    /// A fixture's rough physical envelope in meters, derived from its
    /// GDTF `<Model>` entries — used to draw a marker shaped/sized like the
    /// real fixture instead of a fixed-size sphere.
    private struct GDTFEnvelope {
        let width: Double   // maps to scene X
        let height: Double  // maps to scene Y (up)
        let length: Double  // maps to scene Z
    }

    /// Parses `description.xml` out of a raw .gdtf package and aggregates
    /// its `<Model>` entries into one bounding envelope: width/length take
    /// the largest part (most fixtures are widest at the base), height
    /// sums every part (base + yoke + head stacked), which approximates
    /// overall fixture size without needing the full geometry/kinematic
    /// hierarchy. "Dummy" models are helper/placeholder geometry, not part
    /// of the physical silhouette, so they're skipped.
    private static func gdtfEnvelope(fromPackageData data: Data) -> GDTFEnvelope? {
        guard
            let archive = try? Archive(data: data, accessMode: .read),
            let entry = archive.first(where: { ($0.path as NSString).lastPathComponent == "description.xml" })
        else { return nil }

        var xmlData = Data()
        _ = try? archive.extract(entry) { xmlData.append($0) }
        guard let document = try? XMLDocument(data: xmlData, options: []) else { return nil }

        let modelNodes = (try? document.nodes(forXPath: "//Models/Model")) ?? []
        var maxWidth = 0.0, maxLength = 0.0, totalHeight = 0.0
        var foundAny = false

        for case let model as XMLElement in modelNodes {
            let name = model.attribute(forName: "Name")?.stringValue ?? ""
            if name.lowercased().contains("dummy") { continue }

            guard
                let width = model.attribute(forName: "Width")?.stringValue.flatMap(Double.init),
                let height = model.attribute(forName: "Height")?.stringValue.flatMap(Double.init),
                let length = model.attribute(forName: "Length")?.stringValue.flatMap(Double.init)
            else { continue }

            foundAny = true
            maxWidth = max(maxWidth, width)
            maxLength = max(maxLength, length)
            totalHeight += height
        }

        guard foundAny, maxWidth > 0, maxLength > 0, totalHeight > 0 else { return nil }
        return GDTFEnvelope(width: maxWidth, height: totalHeight, length: maxLength)
    }
}

