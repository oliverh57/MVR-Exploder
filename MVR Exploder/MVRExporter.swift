import Foundation
import ZIPFoundation

enum MVRExportError: Error {
    case noDocumentLoaded
    case cannotOpenSourceArchive
    case cannotCreateDestinationArchive
    case cannotCloneDocument
}

struct MVRExportOptions {
    var includeSceneGeometry: Bool
    var assignLayersByFixtureType: Bool
    var replaceAllWithDummyGDTFs: Bool
    var cleanupEmptyClassesAndLayers: Bool
}

enum MVRExporter {
    /// Writes a new .mvr file containing the (possibly edited) scene XML.
    ///
    /// When `includeSceneGeometry` is false: standalone 3D model files
    /// (anything that isn't the scene XML or a `.gdtf` package) are left out
    /// of the archive, AND `<SceneObject>` nodes are stripped from the XML
    /// itself so importers don't spend time parsing venue geometry that no
    /// longer has model files backing it.
    ///
    /// When `assignLayersByFixtureType` is true, the `<Layers>` section is
    /// rebuilt: every `<Fixture>` moves into a layer named after its GDTF
    /// spec, and every other object moves into a layer named "NONE".
    static func export(_ document: MVRDocument, to destinationURL: URL, options: MVRExportOptions) throws {
        guard let sourceURL = document.originalFileURL, let liveXML = document.xmlDocument else {
            throw MVRExportError.noDocumentLoaded
        }

        // Work on a clone so this export's mutations never touch the live,
        // in-app document — the user can toggle these options and re-export
        // repeatedly without side effects.
        guard let exportXML = liveXML.copy() as? XMLDocument else {
            throw MVRExportError.cannotCloneDocument
        }

        if document.idFieldName == "UnitNumber" {
            normalizeUnitNumberToFixtureID(in: exportXML)
        }
        if !options.includeSceneGeometry {
            removeNonFixtureSceneObjects(from: exportXML)
        }
        if options.assignLayersByFixtureType {
            reassignLayersByFixtureType(in: exportXML)
        }
        if options.cleanupEmptyClassesAndLayers {
            removeEmptyClassesAndLayers(from: exportXML)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        guard let sourceArchive = try? Archive(url: sourceURL, accessMode: .read) else {
            throw MVRExportError.cannotOpenSourceArchive
        }
        guard let newArchive = try? Archive(url: destinationURL, accessMode: .create) else {
            throw MVRExportError.cannotCreateDestinationArchive
        }

        // Work through real files on disk rather than in-memory Data —
        // ZIPFoundation's fileURL-based API is stable across versions,
        // unlike its Data-provider API which has changed signature before.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Make sure every fixture points at a GDTF file that will actually
        // be in the archive — generating dummy placeholders as needed. This
        // also rewrites each affected fixture's <GDTFSpec> to point at the
        // generated dummy, and mutates exportXML in place.
        let dummyGDTFs = try resolveGDTFReferences(
            in: exportXML,
            sourceArchive: sourceArchive,
            injectedFileNames: Set(document.injectedGDTFFiles.keys.map { $0.lowercased() }),
            workDir: workDir,
            replaceAll: options.replaceAllWithDummyGDTFs
        )

        // 1. Write the (now fully resolved) scene description.
        let xmlData = exportXML.xmlData(options: .nodePrettyPrint)
        let xmlTempURL = workDir.appendingPathComponent("GeneralSceneDescription.xml")
        try xmlData.write(to: xmlTempURL)
        try newArchive.addEntry(with: "GeneralSceneDescription.xml", fileURL: xmlTempURL)

        // 2. Copy remaining entries, filtering out scene geometry if asked,
        // and skipping original GDTF packages once every fixture has been
        // repointed at a dummy.
        var writtenEntryNames = Set<String>()
        for entry in sourceArchive {
            guard entry.path != "GeneralSceneDescription.xml" else { continue }

            let isGDTFPackage = entry.path.lowercased().hasSuffix(".gdtf")
            if options.replaceAllWithDummyGDTFs && isGDTFPackage { continue }
            guard options.includeSceneGeometry || isGDTFPackage else { continue }

            let scratchName = (entry.path as NSString).lastPathComponent + "-" + UUID().uuidString
            let entryTempURL = workDir.appendingPathComponent(scratchName)

            _ = try sourceArchive.extract(entry, to: entryTempURL)
            try newArchive.addEntry(with: entry.path, fileURL: entryTempURL)
            writtenEntryNames.insert(entry.path.lowercased())
        }

        // 3. Add any generated dummy GDTF packages.
        for dummy in dummyGDTFs {
            guard !writtenEntryNames.contains(dummy.fileName.lowercased()) else { continue }
            try newArchive.addEntry(with: dummy.fileName, fileURL: dummy.fileURL)
            writtenEntryNames.insert(dummy.fileName.lowercased())
        }

        // 4. Add any GDTF files copied in from another document via
        // Compare mode's "Copy Attributes" feature.
        for (fileName, data) in document.injectedGDTFFiles {
            guard !writtenEntryNames.contains(fileName.lowercased()) else { continue }
            let injectedTempURL = workDir.appendingPathComponent("injected-\(UUID().uuidString).gdtf")
            try data.write(to: injectedTempURL)
            try newArchive.addEntry(with: fileName, fileURL: injectedTempURL)
            writtenEntryNames.insert(fileName.lowercased())
        }
    }

    /// Makes sure every `<Fixture>`'s GDTFSpec resolves to a file that will
    /// actually be present in the exported archive. When `replaceAll` is
    /// false, this only touches fixtures whose referenced .gdtf is genuinely
    /// missing from the source archive — the common "won't import elsewhere"
    /// problem. When true, every fixture gets a dummy regardless.
    ///
    /// Only one dummy is generated per distinct spec name, even if many
    /// fixtures share it. Returns the generated files so the caller can add
    /// them to the new archive.
    private static func resolveGDTFReferences(
        in document: XMLDocument,
        sourceArchive: Archive,
        injectedFileNames: Set<String>,
        workDir: URL,
        replaceAll: Bool
    ) throws -> [(fileName: String, fileURL: URL)] {
        let existingGDTFFilenames = Set(
            sourceArchive.compactMap { entry -> String? in
                guard entry.path.lowercased().hasSuffix(".gdtf") else { return nil }
                return (entry.path as NSString).lastPathComponent.lowercased()
            }
        ).union(injectedFileNames)

        var dummiesByBaseName: [String: (fileName: String, fileURL: URL)] = [:]
        var usedFileNames = Set<String>()
        let fixtureNodes = (try? document.nodes(forXPath: "//Fixture")) ?? []

        for case let fixture as XMLElement in fixtureNodes {
            guard let specElement = fixture.elements(forName: "GDTFSpec").first else { continue }
            let rawSpec = specElement.stringValue ?? ""
            guard !rawSpec.isEmpty else { continue }

            let rawFileName = (rawSpec as NSString).lastPathComponent
            let specFileName = rawFileName.lowercased().hasSuffix(".gdtf") ? rawFileName : rawFileName + ".gdtf"
            let existsInArchive = existingGDTFFilenames.contains(specFileName.lowercased())

            guard replaceAll || !existsInArchive else { continue }

            // Dedupe by the *spec*, not the fixture name — several fixtures
            // sharing one missing GDTF should still collapse to one dummy,
            // even if (in principle) their <Fixture name="…"> ever differed.
            let baseName = (specFileName as NSString).deletingPathExtension
            let resolvedBaseName = baseName.isEmpty ? "Unknown" : baseName
            let dedupeKey = resolvedBaseName.lowercased()

            if let existing = dummiesByBaseName[dedupeKey] {
                specElement.stringValue = existing.fileName
                setGDTFModeToDummyDefault(on: fixture)
                continue
            }

            // The dummy's visible name/filename comes from the fixture's
            // own name — e.g. "GLP JDC Burst 1" — rather than the raw
            // GDTFSpec text, which is often a less recognizable internal
            // identifier (e.g. "JDC Burst 1 New DMX"). Different fixture
            // *types* can legitimately share the same <Fixture name="…">
            // (e.g. a generic "Lighting Device" label used for two
            // unrelated real fixtures), so the resulting file name must be
            // disambiguated against every dummy generated so far, not just
            // ones sharing this dedupeKey — two dummies landing on the same
            // zip entry name silently corrupts the archive.
            let fixtureDisplayName = fixture.attribute(forName: "name")?.stringValue ?? resolvedBaseName
            let sanitizedDisplayName = sanitizeForFileName(fixtureDisplayName)

            var candidateFileName = "Dummy_\(sanitizedDisplayName).gdtf"
            var suffix = 2
            while usedFileNames.contains(candidateFileName.lowercased()) {
                candidateFileName = "Dummy_\(sanitizedDisplayName) (\(suffix)).gdtf"
                suffix += 1
            }
            let dummyFileName = candidateFileName
            usedFileNames.insert(dummyFileName.lowercased())

            let dummyFileURL = try generateDummyGDTF(specName: sanitizedDisplayName, workDir: workDir)
            dummiesByBaseName[dedupeKey] = (dummyFileName, dummyFileURL)
            specElement.stringValue = dummyFileName
            setGDTFModeToDummyDefault(on: fixture)
        }

        return Array(dummiesByBaseName.values)
    }

    /// Dummy GDTFs only ever define one DMXMode (see generateDummyGDTF).
    /// Any fixture repointed at a dummy needs its <GDTFMode> updated to
    /// match that name, or MA3/other importers can resolve the fixture
    /// *type* but not the specific *mode*, leaving the instance unlinked.
    private static func setGDTFModeToDummyDefault(on fixture: XMLElement) {
        if let modeElement = fixture.elements(forName: "GDTFMode").first {
            modeElement.stringValue = dummyModeName
        } else {
            fixture.addChild(XMLElement(name: "GDTFMode", stringValue: dummyModeName))
        }
    }

    /// The single DMXMode name every generated dummy GDTF uses. Shared
    /// between generateDummyGDTF and setGDTFModeToDummyDefault so the two
    /// can't silently drift apart.
    private static let dummyModeName = "Default"

    /// Strips characters that are awkward or invalid in file names (path
    /// separators, colons, quotes, etc.) so a fixture's display name can be
    /// safely used as a dummy GDTF's file name. Collapses runs of removed
    /// characters to a single underscore rather than deleting them outright,
    /// so "Ayrton / Eaglestrike" doesn't collide with an unrelated fixture
    /// that happens to also be named "Ayrton Eaglestrike".
    private static func sanitizeForFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalidCharacters).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    /// Escapes characters that would break XML attribute syntax if a
    /// fixture's raw display name (which can contain &, <, >, or ") is
    /// interpolated straight into the dummy's description.xml.
    private static func xmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Builds a minimal, structurally-valid GDTF package (itself a zip
    /// containing a description.xml) as a placeholder for a fixture type
    /// whose real GDTF isn't available. This is a best-effort skeleton —
    /// one DMX mode with a single no-op channel — not a spec-perfect GDTF.
    private static func generateDummyGDTF(specName: String, workDir: URL) throws -> URL {
        let scratchDir = workDir.appendingPathComponent("gdtf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let fixtureTypeID = UUID().uuidString.uppercased()
        let escapedName = xmlAttributeEscaped(specName)
        let descriptionXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <GDTF DataVersion="1.2">
          <FixtureType Name="\(escapedName)" ShortName="\(escapedName)" LongName="\(escapedName)" Manufacturer="MVR Exploder" Description="Placeholder GDTF generated by MVR Exploder — the original file was missing." FixtureTypeID="\(fixtureTypeID)" RefFT="">
            <AttributeDefinitions>
              <ActivationGroups/>
              <FeatureGroups>
                <FeatureGroup Name="Dimmer" Pretty="Dimmer">
                  <Feature Name="Dimmer"/>
                </FeatureGroup>
              </FeatureGroups>
              <Attributes>
                <Attribute Name="Dimmer" Pretty="Dim" Feature="Dimmer.Dimmer" PhysicalUnit="LuminousIntensity"/>
              </Attributes>
            </AttributeDefinitions>
            <Wheels/>
            <PhysicalDescriptions>
              <Emitters/>
              <CRIs/>
              <FTFilters/>
              <Connectors/>
              <PhysicalProperties>
                <PhysicalPropertiesData/>
              </PhysicalProperties>
              <ColorSpaceCollect/>
              <GamutCollect/>
            </PhysicalDescriptions>
            <Models>
              <Model Name="Body" Length="100" Width="100" Height="100" PrimitiveType="Cube"/>
            </Models>
            <Geometries>
              <Geometry Name="Geometry" Model="Body"/>
            </Geometries>
            <DMXModes>
              <DMXMode Name="\(dummyModeName)" Geometry="Geometry">
                <DMXChannels>
                  <DMXChannel DMXBreak="1" Geometry="Geometry" Highlight="None" InitialFunction="Geometry_Dimmer.Dimmer.Dimmer" Offset="1">
                    <LogicalChannel Attribute="Dimmer" DMXChangeTimeLimit="0.000000" Master="None" MibFade="0.000000" Snap="No">
                      <ChannelFunction Attribute="Dimmer" DMXFrom="0/1" Default="0/1" Name="Dimmer" OriginalAttribute="Dimmer" PhysicalFrom="0.000000" PhysicalTo="1.000000" RealAcceleration="0.000000" RealFade="0.000000">
                        <ChannelSet DMXFrom="0/1" Name="Closed" WheelSlotIndex="0"/>
                        <ChannelSet DMXFrom="255/1" Name="Open" WheelSlotIndex="0"/>
                      </ChannelFunction>
                    </LogicalChannel>
                  </DMXChannel>
                </DMXChannels>
                <Relations/>
                <FTMacros/>
              </DMXMode>
            </DMXModes>
            <Revisions>
              <Revision Text="Generated by MVR Exploder" Date="" UserID="0"/>
            </Revisions>
          </FixtureType>
        </GDTF>
        """

        let descriptionURL = scratchDir.appendingPathComponent("description.xml")
        try descriptionXML.write(to: descriptionURL, atomically: true, encoding: .utf8)

        let gdtfFileURL = workDir.appendingPathComponent("dummy-\(UUID().uuidString).gdtf")
        guard let gdtfArchive = try? Archive(url: gdtfFileURL, accessMode: .create) else {
            throw MVRExportError.cannotCreateDestinationArchive
        }
        try gdtfArchive.addEntry(with: "description.xml", fileURL: descriptionURL)

        return gdtfFileURL
    }

    /// If a file was imported using <UnitNumber> as its ID field, every
    /// exported file should still be consistent: copy each fixture's
    /// UnitNumber value into <FixtureID> (creating it if needed) and drop
    /// <UnitNumber> entirely.
    private static func normalizeUnitNumberToFixtureID(in document: XMLDocument) {
        let fixtureNodes = (try? document.nodes(forXPath: "//Fixture")) ?? []
        for case let fixture as XMLElement in fixtureNodes {
            guard let unitNumberElement = fixture.elements(forName: "UnitNumber").first else { continue }
            let value = unitNumberElement.stringValue ?? ""

            if let existingFixtureID = fixture.elements(forName: "FixtureID").first {
                existingFixtureID.stringValue = value
            } else {
                let newElement = XMLElement(name: "FixtureID", stringValue: value)
                fixture.addChild(newElement)
            }

            unitNumberElement.detach()
        }
    }

    /// Removes non-fixture venue geometry from the scene XML. Rather than
    /// matching a specific tag name like `<SceneObject>`, this removes
    /// *anything* under a Layer's `<ChildList>` that isn't a `<Fixture>` —
    /// different MVR exporters use different tags for venue geometry
    /// (`<Truss>`, `<Support>`, `<VideoScreen>`, `<GeometryReference>`,
    /// `<SceneObject>`, etc.), so matching structurally catches all of them.
    private static func removeNonFixtureSceneObjects(from document: XMLDocument) {
        let childListItems = ((try? document.nodes(forXPath: "//Layers//ChildList/*")) ?? [])
            .compactMap { $0 as? XMLElement }
        for element in childListItems where element.name != "Fixture" {
            element.detach()
        }
    }

    /// Rebuilds `<Layers>`: every fixture moves into a layer named after its
    /// GDTF spec (its fixture type); every other scene object moves into a
    /// single layer named "NONE".
    ///
    /// Assumption worth checking against real files: this expects
    /// `<Fixture>` and other scene objects to live inside
    /// `<Layer><ChildList>…</ChildList></Layer>` under a top-level
    /// `<Layers>` element — the layout described in the MVR spec. If your
    /// exporter nests things differently this may need adjusting.
    /// Removes any `<Layer>` with an empty `<ChildList>`, and any `<Class>`
    /// that no object's `classing` attribute actually references.
    private static func removeEmptyClassesAndLayers(from document: XMLDocument) {
        let layers = ((try? document.nodes(forXPath: "//Layers/Layer")) ?? [])
            .compactMap { $0 as? XMLElement }
        for layer in layers {
            let childCount = layer.elements(forName: "ChildList").first?.children?.count ?? 0
            if childCount == 0 {
                layer.detach()
            }
        }

        let usedClassIDs = Set(
            ((try? document.nodes(forXPath: "//*[@classing]")) ?? [])
                .compactMap { node -> String? in
                    guard let value = (node as? XMLElement)?.attribute(forName: "classing")?.stringValue,
                          !value.isEmpty else { return nil }
                    return value.lowercased()
                }
        )
        let classNodes = ((try? document.nodes(forXPath: "//Classes/Class")) ?? [])
            .compactMap { $0 as? XMLElement }
        for classElement in classNodes {
            let classUUID = classElement.attribute(forName: "uuid")?.stringValue?.lowercased()
            if classUUID == nil || !usedClassIDs.contains(classUUID!) {
                classElement.detach()
            }
        }
    }

    private static func reassignLayersByFixtureType(in document: XMLDocument) {
        guard let scene = document.rootElement()?.elements(forName: "Scene").first else { return }

        let layersElement: XMLElement
        if let existing = scene.elements(forName: "Layers").first {
            layersElement = existing
        } else {
            let newLayers = XMLElement(name: "Layers")
            scene.addChild(newLayers)
            layersElement = newLayers
        }

        let fixtures = ((try? document.nodes(forXPath: "//Layers//Fixture")) ?? [])
            .compactMap { $0 as? XMLElement }
        let allChildListItems = ((try? document.nodes(forXPath: "//Layers//ChildList/*")) ?? [])
            .compactMap { $0 as? XMLElement }
        let nonFixtureObjects = allChildListItems.filter { $0.name != "Fixture" }

        // Detach everything from its current layer before rebuilding.
        for element in fixtures + nonFixtureObjects {
            element.detach()
        }
        for oldLayer in layersElement.elements(forName: "Layer") {
            oldLayer.detach()
        }

        var layersByName: [String: XMLElement] = [:]

        func layer(named name: String) -> XMLElement {
            if let existing = layersByName[name] { return existing }
            let newLayer = XMLElement(name: "Layer")
            if let nameAttr = XMLNode.attribute(withName: "name", stringValue: name) as? XMLNode {
                newLayer.addAttribute(nameAttr)
            }
            if let uuidAttr = XMLNode.attribute(withName: "uuid", stringValue: UUID().uuidString.lowercased()) as? XMLNode {
                newLayer.addAttribute(uuidAttr)
            }
            let childList = XMLElement(name: "ChildList")
            newLayer.addChild(childList)
            layersByName[name] = newLayer
            layersElement.addChild(newLayer)
            return newLayer
        }

        for fixture in fixtures {
            let rawSpec = fixture.elements(forName: "GDTFSpec").first?.stringValue ?? "Unknown"
            let trimmedSpec = (rawSpec as NSString).deletingPathExtension
            let layerName = trimmedSpec.isEmpty ? rawSpec : trimmedSpec
            layer(named: layerName).elements(forName: "ChildList").first?.addChild(fixture)
        }

        let noneLayer = layer(named: "NONE")
        for object in nonFixtureObjects {
            noneLayer.elements(forName: "ChildList").first?.addChild(object)
        }
    }
}
