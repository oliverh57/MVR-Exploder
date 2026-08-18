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
enum MVRIDFieldDetection {
    /// Exactly one of the two fields carries real (non-zero) values.
    case determined(String)
    /// Both fields carry real values (a genuine conflict — seen in real
    /// files, e.g. some fixtures patched via FixtureID and others via
    /// UnitNumber in the same show) or neither does, so there's nothing to
    /// infer from and the user has to say which one is meant.
    case ambiguous
}

/// Holds the parsed MVR scene as a mutable XMLDocument (the source of truth)
/// plus a flattened `fixtures` array for display. Edits made through
/// `applyFixtureIDOffset` / `applyUniverseOffset` / `generateNewUUIDs` /
/// `setUUID` / `setFixtureID` are written straight into the XML nodes, so
/// the document is always ready to export.
final class MVRDocument: ObservableObject {
    @Published var fixtures: [MVRFixture] = []
    @Published var fileName: String = ""

    private(set) var originalFileURL: URL?
    private(set) var xmlDocument: XMLDocument?

    /// Which child element under <Fixture> holds the fixture's ID.
    /// Most MVR exporters use <FixtureID>, but some use <UnitNumber>
    /// instead — the caller asks the user and passes the answer here.
    private(set) var idFieldName: String = "FixtureID"

    /// Extra GDTF package bytes (file name -> raw zip data) pulled in from
    /// another document via Compare mode's "Copy Attributes" feature.
    /// Export includes these in addition to whatever's in the original zip.
    private(set) var injectedGDTFFiles: [String: Data] = [:]

    /// Peeks at `<Fixture>` elements to see whether `<FixtureID>` or
    /// `<UnitNumber>` is unambiguously the one holding real data, so the
    /// caller only needs to ask the user when it genuinely can't tell.
    /// "Real data" means non-zero — an absent or literal-zero element both
    /// mean "no real patch" elsewhere in this app (see MVRFixture), and a
    /// field that's all zeros carries no information either way.
    static func detectIDField(at url: URL) -> MVRIDFieldDetection {
        guard
            let archive = try? Archive(url: url, accessMode: .read),
            let entry = archive["GeneralSceneDescription.xml"]
        else { return .ambiguous }

        var xmlData = Data()
        _ = try? archive.extract(entry) { xmlData.append($0) }
        guard let document = try? XMLDocument(data: xmlData, options: []) else { return .ambiguous }

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

        let document = try XMLDocument(data: xmlData, options: [])

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
                    name: name,
                    originalFixtureID: fixtureID,
                    currentFixtureID: fixtureID,
                    originalAddress: addressValue,
                    currentAddress: addressValue,
                    originalUUID: uuid,
                    currentUUID: uuid,
                    gdtfSpec: gdtfSpec,
                    mode: mode,
                    layerName: layerName,
                    layerUUID: layerUUID,
                    classing: classing,
                    matrixText: matrixText,
                    xmlElement: element,
                    addressElement: addressElement
                )
            )
        }

        self.xmlDocument = document
        self.originalFileURL = url
        self.fileName = url.lastPathComponent
        self.idFieldName = idFieldName
        self.fixtures = parsedFixtures
    }

    /// Drops the loaded file so a new one can be dragged in.
    func clear() {
        fixtures = []
        fileName = ""
        originalFileURL = nil
        xmlDocument = nil
        idFieldName = "FixtureID"
        injectedGDTFFiles = [:]
    }

    /// Adds `offset` to every fixture's current Fixture ID and writes the
    /// change back into the in-memory XML so it's reflected on export.
    func applyFixtureIDOffset(_ offset: Int) {
        for index in fixtures.indices {
            guard let current = fixtures[index].currentFixtureID else { continue }
            let newID = current + offset
            fixtures[index].currentFixtureID = newID

            if let fixtureIDElement = fixtures[index].xmlElement.elements(forName: idFieldName).first {
                fixtureIDElement.stringValue = String(newID)
            }
        }
    }

    /// Adds `offset` universes' worth (512 channels each) to every fixture's
    /// current DMX address and writes the change back into the XML.
    func applyUniverseOffset(_ offset: Int) {
        for index in fixtures.indices {
            guard let current = fixtures[index].currentAddress else { continue }
            let newAddress = current + (offset * 512)
            fixtures[index].currentAddress = newAddress
            fixtures[index].addressElement?.stringValue = String(newAddress)
        }
    }

    /// Assigns a fresh, random UUID to every fixture and writes it back into
    /// the XML's `uuid` attribute.
    func generateNewUUIDs() {
        for index in fixtures.indices {
            let newUUID = UUID().uuidString.lowercased()
            fixtures[index].currentUUID = newUUID
            setUUIDAttribute(newUUID, on: fixtures[index].xmlElement)
        }
    }

    /// Reverts every fixture's ID, address, and uuid back to the values
    /// they had when the file was loaded.
    func resetChanges() {
        for index in fixtures.indices {
            if let originalID = fixtures[index].originalFixtureID {
                fixtures[index].currentFixtureID = originalID
                fixtures[index].xmlElement.elements(forName: idFieldName).first?.stringValue = String(originalID)
            }
            if let originalAddress = fixtures[index].originalAddress {
                fixtures[index].currentAddress = originalAddress
                fixtures[index].addressElement?.stringValue = String(originalAddress)
            }
            let originalUUID = fixtures[index].originalUUID
            fixtures[index].currentUUID = originalUUID
            setUUIDAttribute(originalUUID, on: fixtures[index].xmlElement)
        }
    }

    /// Used by Compare mode to copy a UUID from a matched fixture in
    /// another document into the fixture with the given stable `id`.
    func setUUID(_ newUUID: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        fixtures[index].currentUUID = newUUID
        setUUIDAttribute(newUUID, on: fixtures[index].xmlElement)
    }

    /// Used by Compare mode to copy a Fixture ID from a matched fixture in
    /// another document into the fixture with the given stable `id`.
    func setFixtureID(_ newID: Int, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        fixtures[index].currentFixtureID = newID
        if let element = fixtures[index].xmlElement.elements(forName: idFieldName).first {
            element.stringValue = String(newID)
        }
    }

    /// Removes a fixture from the list and detaches it from the underlying
    /// XML, so it's excluded from export too.
    func deleteFixture(withID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        fixtures[index].xmlElement.detach()
        fixtures.remove(at: index)
    }

    /// Removes every fixture matching the given "non-patched" definition,
    /// detaching each from the underlying XML too.
    func removeFixtures(matching criteria: MVRFixture.UnpatchedCriteria) {
        let idsToRemove = fixtures.filter { $0.isUnpatched(by: criteria) }.map { $0.id }
        for id in idsToRemove {
            deleteFixture(withID: id)
        }
    }

    /// Used by Compare mode to copy a name from a matched fixture in
    /// another document into the fixture with the given stable `id`.
    func setName(_ newName: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        fixtures[index].name = newName
        let element = fixtures[index].xmlElement
        if let attribute = element.attribute(forName: "name") {
            attribute.stringValue = newName
        } else if let attribute = XMLNode.attribute(withName: "name", stringValue: newName) as? XMLNode {
            element.addAttribute(attribute)
        }
    }

    /// Used by Compare mode to copy a DMX patch (absolute address) from a
    /// matched fixture in another document. Creates the <Addresses>/
    /// <Address> structure if the destination fixture didn't have one.
    func setAddress(_ newAddress: Int, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        var fixture = fixtures[index]

        if let existing = fixture.addressElement {
            existing.stringValue = String(newAddress)
            fixture.currentAddress = newAddress
            fixtures[index] = fixture
            return
        }

        let addressesElement: XMLElement
        if let existing = fixture.xmlElement.elements(forName: "Addresses").first {
            addressesElement = existing
        } else {
            let newAddresses = XMLElement(name: "Addresses")
            fixture.xmlElement.addChild(newAddresses)
            addressesElement = newAddresses
        }

        let newAddressElement = XMLElement(name: "Address", stringValue: String(newAddress))
        addressesElement.addChild(newAddressElement)

        fixture.currentAddress = newAddress
        fixture = MVRFixture(
            id: fixture.id,
            name: fixture.name,
            originalFixtureID: fixture.originalFixtureID,
            currentFixtureID: fixture.currentFixtureID,
            originalAddress: fixture.originalAddress,
            currentAddress: newAddress,
            originalUUID: fixture.originalUUID,
            currentUUID: fixture.currentUUID,
            gdtfSpec: fixture.gdtfSpec,
            mode: fixture.mode,
            layerName: fixture.layerName,
            layerUUID: fixture.layerUUID,
            classing: fixture.classing,
            matrixText: fixture.matrixText,
            xmlElement: fixture.xmlElement,
            addressElement: newAddressElement
        )
        fixtures[index] = fixture
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
        }

        let fixtureElement = fixtures[index].xmlElement
        fixtureElement.detach()
        targetLayer.elements(forName: "ChildList").first?.addChild(fixtureElement)

        fixtures[index].layerName = layerName
        fixtures[index].layerUUID = targetLayer.attribute(forName: "uuid")?.stringValue ?? layerUUID
    }

    /// Used by Compare mode to copy the "classing" grouping value from a
    /// matched fixture in another document.
    func setClassing(_ newClassing: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        fixtures[index].classing = newClassing
        let element = fixtures[index].xmlElement
        if let attribute = element.attribute(forName: "classing") {
            attribute.stringValue = newClassing
        } else if let attribute = XMLNode.attribute(withName: "classing", stringValue: newClassing) as? XMLNode {
            element.addAttribute(attribute)
        }
    }

    /// Used by Compare mode to copy 3D position/rotation (<Matrix>) from a
    /// matched fixture in another document.
    func setMatrix(_ newMatrixText: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        fixtures[index].matrixText = newMatrixText
        let element = fixtures[index].xmlElement
        if let existing = element.elements(forName: "Matrix").first {
            existing.stringValue = newMatrixText
        } else {
            element.addChild(XMLElement(name: "Matrix", stringValue: newMatrixText))
        }
    }

    /// Used by Compare mode to copy the GDTF reference (spec + mode) from a
    /// matched fixture in another document.
    func setGDTFSpec(_ newSpec: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        fixtures[index].gdtfSpec = newSpec
        let element = fixtures[index].xmlElement
        if let existing = element.elements(forName: "GDTFSpec").first {
            existing.stringValue = newSpec
        } else {
            element.addChild(XMLElement(name: "GDTFSpec", stringValue: newSpec))
        }
    }

    func setGDTFMode(_ newMode: String, forFixtureAtID id: String) {
        guard let index = fixtures.firstIndex(where: { $0.id == id }) else { return }
        fixtures[index].mode = newMode
        let element = fixtures[index].xmlElement
        if let existing = element.elements(forName: "GDTFMode").first {
            existing.stringValue = newMode
        } else {
            element.addChild(XMLElement(name: "GDTFMode", stringValue: newMode))
        }
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

    private func setUUIDAttribute(_ value: String, on element: XMLElement) {
        if let attribute = element.attribute(forName: "uuid") {
            attribute.stringValue = value
        } else if let attribute = XMLNode.attribute(withName: "uuid", stringValue: value) as? XMLNode {
            element.addAttribute(attribute)
        }
    }
}
