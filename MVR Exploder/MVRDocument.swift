import Foundation
import Combine
import ZIPFoundation

enum MVRDocumentError: Error {
    case cannotOpenArchive
    case sceneDescriptionNotFound
    case xmlParsingFailed
}

/// Result of peeking at an MVR's fixtures to see whether the ID field is
/// actually ambiguous before asking the user about it.
nonisolated enum MVRIDFieldDetection: Sendable {
    /// Exactly one of the two fields carries real (non-zero) values.
    case determined(String)
    /// Both fields carry real values (a genuine conflict — seen in real
    /// files, e.g. some fixtures patched via FixtureID and others via
    /// UnitNumber in the same show) or neither does, so there's nothing to
    /// infer from and the user has to say which one is meant.
    case ambiguous
}

/// One layer, by the two things that identify it. A layer is matched on
/// uuid by MVR consumers, so the name alone is never enough to point a
/// fixture at the right one.
struct MVRLayerRef: Identifiable, Hashable {
    let name: String
    let uuid: String

    var id: String { uuid }
}

/// An MVR's scene description, unzipped and parsed but not yet loaded.
///
/// The slow half of opening a file, so it is done off the main thread;
/// `MVRDocument.load` takes it from there. XMLDocument isn't Sendable, but
/// nothing touches this one until it is handed over.
nonisolated struct MVRSceneFile: @unchecked Sendable {
    let url: URL
    let xml: XMLDocument
    /// Which field holds the fixture IDs, if the file makes that plain.
    let idField: MVRIDFieldDetection
}

/// Holds the parsed MVR scene as a mutable XMLDocument (the source of truth)
/// plus a flattened `fixtures` array for display. Edits made through
/// `applyFixtureIDOffset` / `applyUniverseOffset` / `generateNewUUIDs` /
/// `setUUID` / `setFixtureID` are written straight into the XML nodes, so
/// the document is always ready to export.
final class MVRDocument: ObservableObject {
    /// Every change to a fixture goes through this array — the setters
    /// below all write back into it — so watching it is enough to know
    /// the file has been edited, without each setter having to remember.
    /// Only the setters write it, so it can't drift from the XML.
    @Published private(set) var fixtures: [MVRFixture] = [] {
        didSet { if !isReplacingContents { noteEdit() } }
    }
    @Published var fileName: String = ""

    /// Set by any edit since the file was opened or last exported. The
    /// whole app works on this one document, so edits stay live from tool
    /// to tool; this is what says they haven't been written anywhere yet.
    @Published private(set) var hasUnexportedChanges = false

    /// Edits made to this document since it was loaded or made a draft.
    /// What a tool asks about before throwing a visit's work away.
    @Published private(set) var editCount = 0

    /// True while a load or clear replaces the fixtures wholesale, which
    /// is not an edit.
    private var isReplacingContents = false

    /// Goes up every time a file is loaded, reverts included. A load gives
    /// every fixture a new id, so anything holding ids watches this.
    @Published private(set) var loadGeneration = 0

    /// Whether a file is open. An MVR with no fixtures in it is still an
    /// open file.
    var isLoaded: Bool { xmlDocument != nil }
    /// Every layer in the file, for moving a fixture between them.
    @Published private(set) var availableLayers: [MVRLayerRef] = []

    private(set) var originalFileURL: URL?
    private(set) var xmlDocument: XMLDocument?

    /// Group names from an auto-ID run, keyed by the app's internal fixture
    /// id. Kept out of the fixture list because they describe a *position*,
    /// not a fixture field: nothing in the document changes when one is
    /// set, and they are written to `<UserData>` on export rather than to
    /// anything a console would read.
    @Published private(set) var groupNames: [String: String] = [:]

    /// The Auto ID session this file was last saved with, in *this* load's
    /// fixture ids. Nil until a file carrying one is opened.
    @Published private(set) var autoIDSession: AutoIDStoredSession?

    /// Which child element under <Fixture> holds the fixture's ID.
    /// Most MVR exporters use <FixtureID>, but some use <UnitNumber>
    /// instead — the caller asks the user and passes the answer here.
    private(set) var idFieldName: String = "FixtureID"

    /// Extra GDTF package bytes (file name -> raw zip data) pulled in from
    /// another document via Compare mode's "Copy Attributes" feature.
    /// Export includes these in addition to whatever's in the original zip.
    private(set) var injectedGDTFFiles: [String: Data] = [:]

    /// The window's undo manager, handed over by the view showing this
    /// document. Every edit registers its reverse with it. Nil for a
    /// document nobody edits by hand, like Compare's file B.
    weak var undoManager: UndoManager?

    /// Unzips and parses an MVR's scene description. Safe off the main
    /// thread, and where the time goes when a big file opens.
    nonisolated static func read(from url: URL) throws -> MVRSceneFile {
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            throw MVRDocumentError.cannotOpenArchive
        }
        guard let entry = archive["GeneralSceneDescription.xml"] else {
            throw MVRDocumentError.sceneDescriptionNotFound
        }

        var xmlData = Data()
        _ = try archive.extract(entry) { chunk in
            xmlData.append(chunk)
        }
        let xml = try XMLDocument(data: xmlData, options: [])
        return MVRSceneFile(url: url, xml: xml, idField: detectIDField(in: xml))
    }

    /// `read(from:)` off the main thread, so a big file doesn't stall the
    /// window while it opens.
    static func readInBackground(from url: URL) async throws -> MVRSceneFile {
        try await Task.detached(priority: .userInitiated) { try read(from: url) }.value
    }

    /// Reads the file just to see which field holds its fixture IDs.
    static func detectIDField(at url: URL) -> MVRIDFieldDetection {
        (try? read(from: url))?.idField ?? .ambiguous
    }

    /// Peeks at `<Fixture>` elements to see whether `<FixtureID>` or
    /// `<UnitNumber>` is unambiguously the one holding real data, so the
    /// caller only needs to ask the user when it genuinely can't tell.
    /// "Real data" means non-zero — an absent or literal-zero element both
    /// mean "no real patch" elsewhere in this app (see MVRFixture), and a
    /// field that's all zeros carries no information either way.
    private nonisolated static func detectIDField(in document: XMLDocument) -> MVRIDFieldDetection {
        let fixtureNodes = (try? document.nodes(forXPath: "//Fixture")) ?? []
        var fixtureIDHasData = false
        var unitNumberHasData = false

        for case let element as XMLElement in fixtureNodes {
            if !fixtureIDHasData, let value = element.elements(forName: "FixtureID").first?.stringValue.flatMap(Int.init), value != 0 {
                fixtureIDHasData = true
            }
            if !unitNumberHasData, let value = element.elements(forName: "UnitNumber").first?.stringValue.flatMap(Int.init), value != 0 {
                unitNumberHasData = true
            }
            if fixtureIDHasData && unitNumberHasData { break }
        }

        switch (fixtureIDHasData, unitNumberHasData) {
        case (true, false): return .determined("FixtureID")
        case (false, true): return .determined("UnitNumber")
        default: return .ambiguous
        }
    }

    func load(from url: URL, idFieldName: String) throws {
        load(try Self.read(from: url), idFieldName: idFieldName)
    }

    /// Takes over a file `read(from:)` has already parsed.
    func load(_ file: MVRSceneFile, idFieldName: String) {
        let url = file.url
        let document = file.xml

        let fixtureNodes = (try? document.nodes(forXPath: "//Fixture")) ?? []
        var parsedFixtures: [MVRFixture] = []

        for case let element as XMLElement in fixtureNodes {
            let uuid = element.attribute(forName: "uuid")?.stringValue ?? UUID().uuidString
            let name = element.attribute(forName: "name")?.stringValue ?? "-"

            let fixtureIDText = element.elements(forName: idFieldName).first?.stringValue
            let fixtureID = fixtureIDText.flatMap { Int($0) }

            let addressElement = element.elements(forName: "Addresses").first?
                .elements(forName: "Address").first
            let addressValue = addressElement?.stringValue.flatMap { Int($0) }

            let gdtfSpec = element.elements(forName: "GDTFSpec").first?.stringValue ?? "-"
            let mode = element.elements(forName: "GDTFMode").first?.stringValue ?? "-"

            // Layer name comes from the ancestor <Layer name="…">, not the
            // Fixture element itself — MVR nests Fixture > ChildList > Layer.
            let layerName = (element.parent?.parent as? XMLElement)?
                .attribute(forName: "name")?.stringValue ?? ""
            let layerUUID = (element.parent?.parent as? XMLElement)?
                .attribute(forName: "uuid")?.stringValue ?? ""
            let classing = element.attribute(forName: "classing")?.stringValue ?? ""
            let matrixText = element.elements(forName: "Matrix").first?.stringValue ?? ""

            parsedFixtures.append(
                MVRFixture(
                    id: UUID().uuidString,
                    originalName: name,
                    name: name,
                    originalFixtureID: fixtureID,
                    currentFixtureID: fixtureID,
                    originalAddress: addressValue,
                    currentAddress: addressValue,
                    originalUUID: uuid,
                    currentUUID: uuid,
                    gdtfSpec: gdtfSpec,
                    originalMode: mode,
                    mode: mode,
                    originalLayerName: layerName,
                    layerName: layerName,
                    originalLayerUUID: layerUUID,
                    layerUUID: layerUUID,
                    classing: classing,
                    matrixText: matrixText,
                    xmlElement: element,
                    addressElement: addressElement
                )
            )
        }

        self.xmlDocument = document

        // Names any earlier export left in <UserData>, remapped from MVR
        // uuids onto this session's fixture ids.
        let stored = MVRUserData.groupNames(in: document)
        var restored: [String: String] = [:]
        var idForUUID: [String: String] = [:]
        for fixture in parsedFixtures {
            idForUUID[fixture.originalUUID] = fixture.id
            if let name = stored[fixture.originalUUID] { restored[fixture.id] = name }
        }
        self.groupNames = restored
        // The rest of the session — merges, orders, pinned IDs — through
        // the same remap. Corrections whose fixtures are no longer in the
        // file drop out on the way.
        self.autoIDSession = MVRUserData.session(in: document)?
            .mappingKeys { idForUUID[$0] }
        self.originalFileURL = url
        self.fileName = url.lastPathComponent
        self.idFieldName = idFieldName
        self.injectedGDTFFiles = [:]
        isReplacingContents = true
        self.fixtures = parsedFixtures
        isReplacingContents = false
        hasUnexportedChanges = false
        refreshAvailableLayers()
        undoManager?.removeAllActions(withTarget: self)
        loadGeneration += 1
    }

    /// Throws every change away by reading the opened file again — field
    /// edits, deletes, merges and brought-in GDTFs alike, which resetting
    /// each field couldn't reach.
    func revertToOpenedFile() async throws {
        guard let url = originalFileURL else { return }
        let file = try await Self.readInBackground(from: url)
        load(file, idFieldName: idFieldName)
    }

    private func noteEdit() {
        hasUnexportedChanges = true
        editCount += 1
    }

    // MARK: - Drafts

    /// A copy of this document for one visit to a tool to edit — the
    /// Smart Auto ID rule for every tool: nothing reaches the file until
    /// Apply, which hands the copy back with `adopt(_:)`, and cancelling
    /// just drops it.
    ///
    /// The XML is copied off the main thread; on a 20 MB scene description
    /// that took ~150 ms. The fixtures keep their ids, so group names, the
    /// Auto ID session and anything a tool holds by id mean the same in
    /// both. Nil only if the copy can't be matched up, which it always
    /// should.
    func makeDraft() async -> MVRDocument? {
        guard let xmlDocument else { return nil }
        var targets: [XMLNode] = []
        for fixture in fixtures {
            targets.append(fixture.xmlElement)
            if let address = fixture.addressElement { targets.append(address) }
        }
        let job = DraftCopy(original: xmlDocument, targets: targets)
        let copied = await Task.detached(priority: .userInitiated) { job.run() }.value

        var draftFixtures = fixtures
        for index in draftFixtures.indices {
            guard let element = copied.found[ObjectIdentifier(draftFixtures[index].xmlElement)]
            else { return nil }
            draftFixtures[index].xmlElement = element
            if let address = draftFixtures[index].addressElement {
                guard let copy = copied.found[ObjectIdentifier(address)] else { return nil }
                draftFixtures[index].addressElement = copy
            }
        }

        let draft = MVRDocument()
        draft.xmlDocument = copied.document
        draft.originalFileURL = originalFileURL
        draft.fileName = fileName
        draft.idFieldName = idFieldName
        draft.injectedGDTFFiles = injectedGDTFFiles
        draft.groupNames = groupNames
        draft.autoIDSession = autoIDSession
        draft.availableLayers = availableLayers
        draft.isReplacingContents = true
        draft.fixtures = draftFixtures
        draft.isReplacingContents = false
        draft.hasUnexportedChanges = hasUnexportedChanges
        return draft
    }

    /// Takes a draft's work as this document's own: a tool's Apply.
    func adopt(_ draft: MVRDocument) {
        guard draft.editCount > 0 else { return }
        xmlDocument = draft.xmlDocument
        injectedGDTFFiles = draft.injectedGDTFFiles
        groupNames = draft.groupNames
        autoIDSession = draft.autoIDSession
        availableLayers = draft.availableLayers
        isReplacingContents = true
        fixtures = draft.fixtures
        isReplacingContents = false
        noteEdit()
    }

    /// Records that the document as it stands has been written out.
    func markExported() {
        hasUnexportedChanges = false
    }

    /// Drops the loaded file so a new one can be dragged in.
    func clear() {
        isReplacingContents = true
        fixtures = []
        isReplacingContents = false
        hasUnexportedChanges = false
        fileName = ""
        originalFileURL = nil
        xmlDocument = nil
        groupNames = [:]
        autoIDSession = nil
        availableLayers = []
        idFieldName = "FixtureID"
        injectedGDTFFiles = [:]
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: - Undo

    /// Registers the reverse of an edit. Whatever the reverse does is
    /// itself registered as it runs, which is what makes it redoable.
    private func registerUndo(_ actionName: String, _ reverse: @escaping (MVRDocument) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { reverse($0) }
        undoManager.setActionName(actionName)
    }

    // MARK: - Bulk edits

    /// Adds `offset` to every fixture's current Fixture ID and writes the
    /// change back into the in-memory XML so it's reflected on export.
    func applyFixtureIDOffset(_ offset: Int) {
        var newIDs: [String: Int] = [:]
        for fixture in fixtures {
            if let current = fixture.currentFixtureID { newIDs[fixture.id] = current + offset }
        }
        setFixtureIDs(newIDs)
    }

    /// Adds `offset` universes' worth (512 channels each) to every fixture's
    /// current DMX address and writes the change back into the XML.
    func applyUniverseOffset(_ offset: Int) {
        var newAddresses: [String: Int?] = [:]
        for fixture in fixtures {
            if let current = fixture.currentAddress {
                newAddresses.updateValue(current + offset * 512, forKey: fixture.id)
            }
        }
        changeAddresses(newAddresses)
    }

    /// Assigns a fresh, random UUID to every fixture and writes it back into
    /// the XML's `uuid` attribute.
    func generateNewUUIDs() {
        var newUUIDs: [String: String] = [:]
        for fixture in fixtures { newUUIDs[fixture.id] = UUID().uuidString.lowercased() }
        changeUUIDs(newUUIDs)
    }

    /// Reverts every fixture back to the values it had when the file was
    /// loaded.
    ///
    /// Iterates a snapshot and only touches fields that actually differ.
    /// Resetting unconditionally meant every fixture went through the layer
    /// setter — a DOM detach and re-attach plus a rebuild of the layer cache
    /// each time — so resetting one edited Fixture ID did that work 661
    /// times over and hung the app.
    func resetChanges() {
        for fixture in fixtures {
            for field in MVRFixtureField.allCases where fixture.isEdited(field) {
                resetField(field, forFixtureAtID: fixture.id)
            }
        }
    }

    /// Records the group each fixture ended up in, from an auto-ID run.
    func setGroupNames(_ names: [String: String]) {
        let previous = groupNames
        groupNames = names
        noteEdit()
        registerUndo("Group Names") { $0.setGroupNames(previous) }
    }

    /// Records the Auto ID session, so the next export carries it and the
    /// next open picks it back up.
    func setAutoIDSession(_ session: AutoIDStoredSession?) {
        let previous = autoIDSession
        autoIDSession = session
        noteEdit()
        registerUndo("Smart Auto ID") { $0.setAutoIDSession(previous) }
    }

    /// Reverts a single field of a single fixture, leaving its other edits
    /// alone. Routed through the same setters as an edit, so the XML and the
    /// in-memory fixture can't drift apart.
    func resetField(_ field: MVRFixtureField, forFixtureAtID id: String) {
        guard let fixture = fixtures.first(where: { $0.id == id }), fixture.isEdited(field) else { return }

        switch field {
        case .name:
            setName(fixture.originalName, forFixtureAtID: id)
        case .fixtureID:
            // Nil included: a fixture numbered here that had no ID goes
            // back to having none.
            changeFixtureIDs([id: fixture.originalFixtureID])
        case .uuid:
            setUUID(fixture.originalUUID, forFixtureAtID: id)
        case .layer:
            setLayer(name: fixture.originalLayerName, uuid: fixture.originalLayerUUID, forFixtureAtID: id)
        case .universe, .channel:
            changeAddresses([id: fixture.originalAddress])
        case .mode:
            setGDTFMode(fixture.originalMode, forFixtureAtID: id)
        }
    }

    /// Rebuilds the cached layer list from the document.
    ///
    /// Deliberately cached rather than computed on demand: the layer picker
    /// asks for this from inside a table cell, so a computed version ran an
    /// XPath over the whole scene description once per visible row per
    /// render — which on a 6.8MB file made the table crawl.
    private func refreshAvailableLayers() {
        var seen: Set<String> = []
        var result: [MVRLayerRef] = []
        for case let layer as XMLElement in (try? xmlDocument?.nodes(forXPath: "//Layer")) ?? [] {
            guard let uuid = layer.attribute(forName: "uuid")?.stringValue, seen.insert(uuid).inserted else { continue }
            result.append(MVRLayerRef(
                name: layer.attribute(forName: "name")?.stringValue ?? "Unnamed layer",
                uuid: uuid))
        }
        availableLayers = result
    }

    /// Used by Compare mode to copy a UUID from a matched fixture in
    /// another document into the fixture with the given stable `id`.
    func setUUID(_ newUUID: String, forFixtureAtID id: String) {
        changeUUIDs([id: newUUID])
    }

    /// Several UUIDs in one change: one update, one undo step.
    private func changeUUIDs(_ newUUIDs: [String: String]) {
        var updated = fixtures
        var previous: [String: String] = [:]
        for index in updated.indices {
            guard let newUUID = newUUIDs[updated[index].id] else { continue }
            previous[updated[index].id] = updated[index].currentUUID
            updated[index].currentUUID = newUUID
            setUUIDAttribute(newUUID, on: updated[index].xmlElement)
        }
        guard !previous.isEmpty else { return }
        fixtures = updated
        registerUndo(previous.count == 1 ? "Change UUID" : "New UUIDs") { $0.changeUUIDs(previous) }
    }

    /// Used by Compare mode to copy a Fixture ID from a matched fixture in
    /// another document into the fixture with the given stable `id`.
    func setFixtureID(_ newID: Int, forFixtureAtID id: String) {
        setFixtureIDs([id: newID])
    }

    /// Several Fixture IDs in one change — an Auto ID run, a move on the
    /// ID map — so the fixture list updates once and undoes in one step.
    func setFixtureIDs(_ newIDs: [String: Int]) {
        changeFixtureIDs(newIDs.mapValues { Optional($0) })
    }

    /// Nil takes a fixture's ID away, which only an undo or a reset does.
    private func changeFixtureIDs(_ newIDs: [String: Int?]) {
        var updated = fixtures
        var previous: [String: Int?] = [:]
        for index in updated.indices {
            guard let newID = newIDs[updated[index].id] else { continue }
            previous.updateValue(updated[index].currentFixtureID, forKey: updated[index].id)
            updated[index].currentFixtureID = newID

            // A fixture that had no ID has no element to write into, and
            // without one the new number never reached the exported file.
            let element = updated[index].xmlElement
            let existing = element.elements(forName: idFieldName).first
            switch (newID, existing) {
            case let (id?, field?): field.stringValue = String(id)
            case let (id?, nil): element.addChild(XMLElement(name: idFieldName, stringValue: String(id)))
            case (nil, let field?): field.detach()
            case (nil, nil): break
            }
        }
        guard !previous.isEmpty else { return }
        fixtures = updated
        registerUndo(previous.count == 1 ? "Change Fixture ID" : "Change Fixture IDs") {
            $0.changeFixtureIDs(previous)
        }
    }

    /// Removes a fixture from the list and detaches it from the underlying
    /// XML, so it's excluded from export too.
    func deleteFixture(withID id: String) {
        deleteFixtures(withIDs: [id])
    }

    /// A deleted fixture and where it came out of, so an undo can put it
    /// back exactly.
    private struct RemovedFixture {
        let fixture: MVRFixture
        let position: Int
        let parent: XMLElement?
        let childIndex: Int
    }

    /// Removes several fixtures in one pass, for deleting a multiple
    /// selection from a table.
    func deleteFixtures(withIDs ids: Set<String>) {
        let removed = fixtures.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { position, fixture in
                RemovedFixture(
                    fixture: fixture, position: position,
                    parent: fixture.xmlElement.parent as? XMLElement,
                    childIndex: fixture.xmlElement.index)
            }
        guard !removed.isEmpty else { return }
        for entry in removed { entry.fixture.xmlElement.detach() }
        fixtures.removeAll { ids.contains($0.id) }
        registerUndo(removed.count == 1 ? "Delete Fixture" : "Delete Fixtures") { $0.restore(removed) }
    }

    /// Puts deleted fixtures back where they were, in the list and the XML.
    /// In ascending order, so each index means what it did before the
    /// delete.
    private func restore(_ removed: [RemovedFixture]) {
        for entry in removed.sorted(by: { $0.childIndex < $1.childIndex }) {
            guard let parent = entry.parent else { continue }
            parent.insertChild(entry.fixture.xmlElement, at: min(entry.childIndex, parent.childCount))
        }
        var updated = fixtures
        for entry in removed {
            updated.insert(entry.fixture, at: min(entry.position, updated.count))
        }
        fixtures = updated
        let ids = Set(removed.map(\.fixture.id))
        registerUndo(removed.count == 1 ? "Delete Fixture" : "Delete Fixtures") {
            $0.deleteFixtures(withIDs: ids)
        }
    }

    /// Removes every fixture matching the given "non-patched" definition,
    /// detaching each from the underlying XML too.
    func removeFixtures(matching criteria: MVRFixture.UnpatchedCriteria) {
        deleteFixtures(withIDs: Set(fixtures.filter { $0.isUnpatched(by: criteria) }.map(\.id)))
    }

    /// Used by Compare mode to copy a name from a matched fixture in
    /// another document into the fixture with the given stable `id`.
    func setName(_ newName: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        let previous = fixtures[index].name
        fixtures[index].name = newName
        let element = fixtures[index].xmlElement
        if let attribute = element.attribute(forName: "name") {
            attribute.stringValue = newName
        } else if let attribute = XMLNode.attribute(withName: "name", stringValue: newName) as? XMLNode {
            element.addAttribute(attribute)
        }
        registerUndo("Rename") { $0.setName(previous, forFixtureAtID: id) }
    }

    /// Used by Compare mode to copy a DMX patch (absolute address) from a
    /// matched fixture in another document. Creates the <Addresses>/
    /// <Address> structure if the destination fixture didn't have one.
    func setAddress(_ newAddress: Int, forFixtureAtID id: String) {
        changeAddresses([id: newAddress])
    }

    /// Several addresses in one change — a move on the universe map — so
    /// the fixture list updates once and undoes in one step.
    func setAddresses(_ newAddresses: [String: Int]) {
        changeAddresses(newAddresses.mapValues { Optional($0) })
    }

    /// Several addresses in one change. Nil unpatches, which only an undo
    /// or a reset does.
    private func changeAddresses(_ newAddresses: [String: Int?]) {
        var updated = fixtures
        var previous: [String: Int?] = [:]
        for index in updated.indices {
            guard let newAddress = newAddresses[updated[index].id] else { continue }
            previous.updateValue(updated[index].currentAddress, forKey: updated[index].id)
            updated[index].currentAddress = newAddress

            guard let newAddress else {
                updated[index].addressElement?.detach()
                updated[index].addressElement = nil
                continue
            }
            if let existing = updated[index].addressElement {
                existing.stringValue = String(newAddress)
                continue
            }
            let fixtureElement = updated[index].xmlElement
            let addressesElement: XMLElement
            if let existing = fixtureElement.elements(forName: "Addresses").first {
                addressesElement = existing
            } else {
                addressesElement = XMLElement(name: "Addresses")
                fixtureElement.addChild(addressesElement)
            }
            let newAddressElement = XMLElement(name: "Address", stringValue: String(newAddress))
            addressesElement.addChild(newAddressElement)
            updated[index].addressElement = newAddressElement
        }
        guard !previous.isEmpty else { return }
        fixtures = updated
        registerUndo(previous.count == 1 ? "Change Patch" : "Change Patches") {
            $0.changeAddresses(previous)
        }
    }

    /// Used by Compare mode to move a fixture into the layer matching the
    /// source layer's identity from another document, creating that layer
    /// here if it doesn't exist. The uuid is treated as authoritative — a
    /// same-named layer with a different uuid gets its uuid realigned,
    /// since consumers like MA identify layers by uuid, not name, and would
    /// otherwise import a "duplicate" layer alongside the real one.
    func setLayer(name layerName: String, uuid layerUUID: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        guard !layerName.isEmpty else { return }
        guard let scene = xmlDocument?.rootElement()?.elements(forName: "Scene").first else { return }
        let previous = (name: fixtures[index].layerName, uuid: fixtures[index].layerUUID)

        let layersElement: XMLElement
        if let existing = scene.elements(forName: "Layers").first {
            layersElement = existing
        } else {
            let newLayers = XMLElement(name: "Layers")
            scene.addChild(newLayers)
            layersElement = newLayers
        }

        let existingLayers = layersElement.elements(forName: "Layer")
        let targetLayer: XMLElement
        var createdLayer = false

        if !layerUUID.isEmpty, let byUUID = existingLayers.first(where: {
            $0.attribute(forName: "uuid")?.stringValue?.lowercased() == layerUUID.lowercased()
        }) {
            targetLayer = byUUID
            if let nameAttr = byUUID.attribute(forName: "name") {
                nameAttr.stringValue = layerName
            }
        } else if let byName = existingLayers.first(where: { $0.attribute(forName: "name")?.stringValue == layerName }) {
            targetLayer = byName
            if !layerUUID.isEmpty {
                if let uuidAttr = byName.attribute(forName: "uuid") {
                    uuidAttr.stringValue = layerUUID
                } else if let newAttr = XMLNode.attribute(withName: "uuid", stringValue: layerUUID) as? XMLNode {
                    byName.addAttribute(newAttr)
                }
            }
        } else {
            let newLayer = XMLElement(name: "Layer")
            if let nameAttr = XMLNode.attribute(withName: "name", stringValue: layerName) as? XMLNode {
                newLayer.addAttribute(nameAttr)
            }
            let resolvedUUID = layerUUID.isEmpty ? UUID().uuidString.lowercased() : layerUUID
            if let uuidAttr = XMLNode.attribute(withName: "uuid", stringValue: resolvedUUID) as? XMLNode {
                newLayer.addAttribute(uuidAttr)
            }
            newLayer.addChild(XMLElement(name: "ChildList"))
            layersElement.addChild(newLayer)
            targetLayer = newLayer
            createdLayer = true
        }

        let fixtureElement = fixtures[index].xmlElement
        fixtureElement.detach()
        targetLayer.elements(forName: "ChildList").first?.addChild(fixtureElement)

        fixtures[index].layerName = layerName
        fixtures[index].layerUUID = targetLayer.attribute(forName: "uuid")?.stringValue ?? layerUUID
        // Only when the layer list actually changed — this runs an XPath over
        // the whole scene description, so doing it on every move is enough to
        // stall a bulk operation.
        if createdLayer { refreshAvailableLayers() }
        registerUndo("Change Layer") {
            $0.setLayer(name: previous.name, uuid: previous.uuid, forFixtureAtID: id)
        }
    }

    /// Used by Compare mode to copy the "classing" grouping value from a
    /// matched fixture in another document.
    func setClassing(_ newClassing: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        let previous = fixtures[index].classing
        fixtures[index].classing = newClassing
        let element = fixtures[index].xmlElement
        if let attribute = element.attribute(forName: "classing") {
            attribute.stringValue = newClassing
        } else if let attribute = XMLNode.attribute(withName: "classing", stringValue: newClassing) as? XMLNode {
            element.addAttribute(attribute)
        }
        registerUndo("Change Class") { $0.setClassing(previous, forFixtureAtID: id) }
    }

    /// Used by Compare mode to copy 3D position/rotation (<Matrix>) from a
    /// matched fixture in another document.
    func setMatrix(_ newMatrixText: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        let previous = fixtures[index].matrixText
        fixtures[index].matrixText = newMatrixText
        let element = fixtures[index].xmlElement
        if let existing = element.elements(forName: "Matrix").first {
            existing.stringValue = newMatrixText
        } else {
            element.addChild(XMLElement(name: "Matrix", stringValue: newMatrixText))
        }
        registerUndo("Move Fixture") { $0.setMatrix(previous, forFixtureAtID: id) }
    }

    /// Used by Compare mode to copy the GDTF reference (spec + mode) from a
    /// matched fixture in another document.
    func setGDTFSpec(_ newSpec: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        let previous = fixtures[index].gdtfSpec
        fixtures[index].gdtfSpec = newSpec
        let element = fixtures[index].xmlElement
        if let existing = element.elements(forName: "GDTFSpec").first {
            existing.stringValue = newSpec
        } else {
            element.addChild(XMLElement(name: "GDTFSpec", stringValue: newSpec))
        }
        registerUndo("Change Fixture Type") { $0.setGDTFSpec(previous, forFixtureAtID: id) }
    }

    func setGDTFMode(_ newMode: String, forFixtureAtID id: String) {
        setGDTFModes([id: newMode])
    }

    /// Several modes in one change — Mode Swap moving a whole type — so
    /// the fixture list updates once and undoes in one step.
    func setGDTFModes(_ newModes: [String: String]) {
        var updated = fixtures
        var previous: [String: String] = [:]
        for index in updated.indices {
            guard let newMode = newModes[updated[index].id] else { continue }
            previous[updated[index].id] = updated[index].mode
            updated[index].mode = newMode
            let element = updated[index].xmlElement
            if let existing = element.elements(forName: "GDTFMode").first {
                existing.stringValue = newMode
            } else {
                element.addChild(XMLElement(name: "GDTFMode", stringValue: newMode))
            }
        }
        guard !previous.isEmpty else { return }
        fixtures = updated
        registerUndo("Change Mode") { $0.setGDTFModes(previous) }
    }

    /// Reads the raw bytes of a .gdtf package from this document's original
    /// zip, matching by file name (case-insensitive, with or without the
    /// ".gdtf" extension present in the spec text — some exporters omit
    /// it). Returns nil if this document's source doesn't actually contain
    /// that GDTF — which is exactly the "missing GDTF" case the dummy
    /// generator also handles.
    func gdtfFileData(forSpec rawSpec: String) -> Data? {
        guard let url = originalFileURL, let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        let rawFileName = (rawSpec as NSString).lastPathComponent.lowercased()
        let withExtension = rawFileName.hasSuffix(".gdtf") ? rawFileName : rawFileName + ".gdtf"
        let candidates: Set<String> = [rawFileName, withExtension]

        guard let entry = archive.first(where: { candidates.contains(($0.path as NSString).lastPathComponent.lowercased()) }) else {
            return nil
        }
        var data = Data()
        _ = try? archive.extract(entry) { chunk in data.append(chunk) }
        return data.isEmpty ? nil : data
    }

    /// Stores extra GDTF bytes to be included at export time, alongside
    /// whatever this document's own original zip provides.
    func injectGDTFFile(named fileName: String, data: Data) {
        injectedGDTFFiles[fileName] = data
        noteEdit()
    }

    /// Copies a fixture's GDTF reference AND the underlying .gdtf bytes
    /// from another (already-loaded) document into a fixture in this one.
    /// If the source document's own zip doesn't actually contain that
    /// GDTF file either, only the XML reference is copied — export's
    /// existing dummy-generation will still cover the gap.
    func copyGDTF(from sourceDocument: MVRDocument, sourceFixtureID: String, toFixtureAtID destinationFixtureID: String) {
        guard let sourceFixture = sourceDocument.fixtures.first(where: { $0.id == sourceFixtureID }) else { return }

        setGDTFSpec(sourceFixture.gdtfSpec, forFixtureAtID: destinationFixtureID)
        setGDTFMode(sourceFixture.mode, forFixtureAtID: destinationFixtureID)

        if let data = sourceDocument.gdtfFileData(forSpec: sourceFixture.gdtfSpec) {
            // Normalized the same way the exporter itself normalizes spec
            // filenames, so the injected entry's name always matches what
            // resolveGDTFReferences looks for later.
            let rawFileName = (sourceFixture.gdtfSpec as NSString).lastPathComponent
            let fileName = rawFileName.lowercased().hasSuffix(".gdtf") ? rawFileName : rawFileName + ".gdtf"
            injectGDTFFile(named: fileName, data: data)
        }
    }

    // MARK: - Merging

    /// Copies whole fixtures from another document into this one: Compare
    /// mode's merge, B into A.
    ///
    /// Each arrives as a deep copy of its `<Fixture>` element, so whatever
    /// the source carries — protocols, focus, mappings — comes with it.
    /// Its layer is found here by uuid, then by name, and made only if
    /// neither exists; this file's own layers are never renamed or
    /// re-identified to suit an incoming fixture. Its GDTF comes across
    /// when this file has nothing by that name, and so does its class.
    ///
    /// A UUID this file already uses is replaced, because two fixtures
    /// sharing one is a broken file. That only happens when the two files
    /// were matched on Fixture ID — matched on UUID, a fixture only in B
    /// has a UUID A hasn't got by definition. Every other value is kept as
    /// it was, clashing Fixture IDs included: those are for the user to
    /// see and decide on, not for a merge to quietly renumber.
    ///
    /// Returns this document's ids for the fixtures added, in the order
    /// they were asked for.
    @discardableResult
    func importFixtures(withIDs ids: [String], from source: MVRDocument) -> [String] {
        guard let scene = xmlDocument?.rootElement()?.elements(forName: "Scene").first else { return [] }

        let byID = Dictionary(source.fixtures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var usedUUIDs = Set(fixtures.map { $0.currentUUID.lowercased() })
        var arrived: [MVRFixture] = []
        var madeLayer = false

        for id in ids {
            guard let incoming = byID[id],
                  let element = incoming.xmlElement.copy() as? XMLElement
            else { continue }

            var uuid = incoming.currentUUID
            if usedUUIDs.contains(uuid.lowercased()) {
                uuid = UUID().uuidString.lowercased()
                setUUIDAttribute(uuid, on: element)
            }
            usedUUIDs.insert(uuid.lowercased())

            // The two files may keep the ID in different fields — one in
            // <FixtureID>, the other in <UnitNumber> — so it is written
            // into the one this file reads.
            if let fixtureID = incoming.currentFixtureID {
                if let field = element.elements(forName: idFieldName).first {
                    field.stringValue = String(fixtureID)
                } else {
                    element.addChild(XMLElement(name: idFieldName, stringValue: String(fixtureID)))
                }
            }

            let (layer, created) = importLayer(
                named: incoming.layerName, uuid: incoming.layerUUID, in: scene)
            madeLayer = madeLayer || created
            layer.elements(forName: "ChildList").first?.addChild(element)

            carryGDTF(spec: incoming.gdtfSpec, from: source)
            if !incoming.classing.isEmpty {
                carryAuxiliary("Class", uuid: incoming.classing, from: source, into: scene)
            }
            if let position = element.elements(forName: "Position").first?.stringValue,
               !position.isEmpty {
                carryAuxiliary("Position", uuid: position, from: source, into: scene)
            }

            let layerName = layer.attribute(forName: "name")?.stringValue ?? ""
            let layerUUID = layer.attribute(forName: "uuid")?.stringValue ?? ""
            let address = element.elements(forName: "Addresses").first?
                .elements(forName: "Address").first

            // New to this file, so what it arrived as is its original:
            // nothing about it shows as edited until it is.
            arrived.append(MVRFixture(
                id: UUID().uuidString,
                originalName: incoming.name,
                name: incoming.name,
                originalFixtureID: incoming.currentFixtureID,
                currentFixtureID: incoming.currentFixtureID,
                originalAddress: incoming.currentAddress,
                currentAddress: incoming.currentAddress,
                originalUUID: uuid,
                currentUUID: uuid,
                gdtfSpec: incoming.gdtfSpec,
                originalMode: incoming.mode,
                mode: incoming.mode,
                originalLayerName: layerName,
                layerName: layerName,
                originalLayerUUID: layerUUID,
                layerUUID: layerUUID,
                classing: incoming.classing,
                matrixText: incoming.matrixText,
                xmlElement: element,
                addressElement: address))
        }

        // One assignment, so the table redraws once for the whole batch.
        fixtures += arrived
        if madeLayer { refreshAvailableLayers() }
        // Undoing takes the fixtures back out. Any layer, GDTF or class
        // that came with them stays; nothing points at it any more.
        let arrivedIDs = arrived.map(\.id)
        if !arrivedIDs.isEmpty {
            registerUndo("Merge Fixtures") { $0.deleteFixtures(withIDs: Set(arrivedIDs)) }
        }
        return arrivedIDs
    }

    /// The layer an imported fixture goes into: this file's layer with the
    /// same uuid, else the same name, else a new one made to match.
    private func importLayer(
        named name: String, uuid: String, in scene: XMLElement
    ) -> (layer: XMLElement, created: Bool) {
        let layers: XMLElement
        if let existing = scene.elements(forName: "Layers").first {
            layers = existing
        } else {
            layers = XMLElement(name: "Layers")
            scene.addChild(layers)
        }
        let existing = layers.elements(forName: "Layer")

        if !uuid.isEmpty, let match = existing.first(where: {
            $0.attribute(forName: "uuid")?.stringValue?.lowercased() == uuid.lowercased()
        }) {
            return (match, false)
        }
        let wanted = name.isEmpty ? "Imported" : name
        if let match = existing.first(where: { $0.attribute(forName: "name")?.stringValue == wanted }) {
            return (match, false)
        }

        let layer = XMLElement(name: "Layer")
        if let attribute = XMLNode.attribute(withName: "name", stringValue: wanted) as? XMLNode {
            layer.addAttribute(attribute)
        }
        let resolvedUUID = uuid.isEmpty ? UUID().uuidString.lowercased() : uuid
        if let attribute = XMLNode.attribute(withName: "uuid", stringValue: resolvedUUID) as? XMLNode {
            layer.addAttribute(attribute)
        }
        layer.addChild(XMLElement(name: "ChildList"))
        layers.addChild(layer)
        return (layer, true)
    }

    /// Brings a GDTF across from another document when this one has
    /// nothing by that name, either in its own file or already brought in.
    private func carryGDTF(spec: String, from source: MVRDocument) {
        let raw = (spec as NSString).lastPathComponent
        guard !raw.isEmpty, raw != "-" else { return }
        let fileName = raw.lowercased().hasSuffix(".gdtf") ? raw : raw + ".gdtf"
        guard injectedGDTFFiles[fileName] == nil, gdtfFileData(forSpec: spec) == nil else { return }

        if let data = source.gdtfFileData(forSpec: spec) ?? source.injectedGDTFFiles[fileName] {
            injectGDTFFile(named: fileName, data: data)
        }
    }

    /// Copies an `<AUXData>` entry — a class or a position — that an
    /// imported fixture refers to, when this file hasn't got it. Without
    /// it the fixture would point at a uuid nothing in this file defines.
    private func carryAuxiliary(
        _ kind: String, uuid: String, from source: MVRDocument, into scene: XMLElement
    ) {
        func entry(in scene: XMLElement?) -> XMLElement? {
            scene?.elements(forName: "AUXData").first?
                .elements(forName: kind)
                .first { $0.attribute(forName: "uuid")?.stringValue?.lowercased() == uuid.lowercased() }
        }
        guard entry(in: scene) == nil,
              let sourceScene = source.xmlDocument?.rootElement()?.elements(forName: "Scene").first,
              let found = entry(in: sourceScene),
              let copy = found.copy() as? XMLElement
        else { return }

        let auxiliary: XMLElement
        if let existing = scene.elements(forName: "AUXData").first {
            auxiliary = existing
        } else {
            // AUXData comes before Layers in a scene description.
            auxiliary = XMLElement(name: "AUXData")
            scene.insertChild(auxiliary, at: 0)
        }
        auxiliary.addChild(copy)
    }

    private func setUUIDAttribute(_ value: String, on element: XMLElement) {
        if let attribute = element.attribute(forName: "uuid") {
            attribute.stringValue = value
        } else if let attribute = XMLNode.attribute(withName: "uuid", stringValue: value) as? XMLNode {
            element.addAttribute(attribute)
        }
    }
}

/// The XML half of making a draft: a deep copy, and the copy's node for
/// each of the original nodes the fixtures point at. Found by walking the
/// two trees side by side, since a copy is the same shape as its original.
/// Runs off the main thread; nothing edits the original meanwhile.
private nonisolated struct DraftCopy: @unchecked Sendable {
    let original: XMLDocument
    let targets: [XMLNode]

    struct Result: @unchecked Sendable {
        let document: XMLDocument
        let found: [ObjectIdentifier: XMLElement]
    }

    func run() -> Result {
        let copy = original.copy() as! XMLDocument
        let wanted = Set(targets.map(ObjectIdentifier.init))
        var found: [ObjectIdentifier: XMLElement] = [:]
        var pairs: [(XMLNode, XMLNode)] = [(original, copy)]
        while let (from, to) = pairs.popLast(), found.count < wanted.count {
            if wanted.contains(ObjectIdentifier(from)), let element = to as? XMLElement {
                found[ObjectIdentifier(from)] = element
            }
            guard let fromChildren = from.children, let toChildren = to.children,
                  fromChildren.count == toChildren.count else { continue }
            for pair in zip(fromChildren, toChildren) where pair.0.kind == .element {
                pairs.append(pair)
            }
        }
        return Result(document: copy, found: found)
    }
}
