import Foundation

/// MVR's `<UserData>` block — the standard place for tool-private data.
///
/// Each `<Data provider="…">` inside it belongs to one application, and an
/// importer skips providers it doesn't recognise. That isn't a convention
/// this app invented: Vectorworks already ships it in real files, one
/// `<VWEntry key="{fixture uuid}">` per fixture pointing at its `.lit`
/// file, and every other tool in the chain leaves it alone. grandMA3 reads
/// fixtures, layers and classes — not this.
///
/// So it's where group names go: they survive the round trip and reach
/// anything that wants them, without turning into layers or classes that a
/// console would import as patch structure.
enum MVRUserData {
    static let provider = "MVR Exploder"
    static let version = "1.0"

    /// Keyed by the fixture's MVR `uuid`, matching how Vectorworks keys its
    /// own entries — a fixture keeps its uuid when the list is reordered or
    /// re-layered, which its position in the file does not.
    static func groupNames(in document: XMLDocument) -> [String: String] {
        guard let data = dataElement(in: document, creating: false) else { return [:] }

        var names: [String: String] = [:]
        for case let entry as XMLElement in data.elements(forName: "Group") {
            guard let key = entry.attribute(forName: "key")?.stringValue else { continue }
            let name = (entry.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            names[key] = name
        }
        return names
    }

    /// Replaces this app's block, leaving every other provider untouched —
    /// wiping the Vectorworks entries on the way past would lose data the
    /// user never asked us to touch.
    static func write(
        names: [String: String], session: AutoIDStoredSession?,
        gdtfSources: [String: GDTFSource] = [:], in document: XMLDocument
    ) {
        guard let root = document.rootElement() else { return }

        // Always clear ours first, so a re-export can't stack duplicates
        // and clearing every name really does remove the block.
        if let existing = dataElement(in: document, creating: false) {
            existing.detach()
        }
        let session = (session?.isEmpty ?? true) ? nil : session
        guard !names.isEmpty || session != nil || !gdtfSources.isEmpty else { return }

        let data = XMLElement(name: "Data")
        data.addAttribute(XMLNode.attribute(withName: "provider", stringValue: provider) as! XMLNode)
        data.addAttribute(XMLNode.attribute(withName: "ver", stringValue: version) as! XMLNode)

        // Sorted so two exports of the same document produce the same file.
        for key in names.keys.sorted() {
            let entry = XMLElement(name: "Group", stringValue: names[key])
            entry.addAttribute(XMLNode.attribute(withName: "key", stringValue: key) as! XMLNode)
            data.addChild(entry)
        }

        for file in gdtfSources.keys.sorted() {
            guard let source = gdtfSources[file] else { continue }
            let entry = XMLElement(name: "GDTFSource")
            for (name, value) in [
                ("file", file), ("rid", String(source.rid)), ("manufacturer", source.manufacturer),
                ("fixture", source.fixture), ("revision", source.revision), ("uploader", source.uploader),
                ("modified", String(Int(source.modified.timeIntervalSince1970))),
            ] {
                entry.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
            }
            data.addChild(entry)
        }

        // Last, so the readable per-fixture entries come first when
        // anyone opens the file to look.
        if let session, let json = try? session.encoded() {
            data.addChild(XMLElement(name: "Session", stringValue: json))
        }

        userDataElement(in: root, creating: true)?.addChild(data)
    }

    // MARK: - GDTF sources

    /// Where a GDTF came from, when this app put it in the file: the GDTF
    /// Share revision it was downloaded as. A GDTF's contents can't prove
    /// where it came from, so this is what tells a genuine replacement
    /// from the stand-in it replaced, after the file is saved and opened
    /// again.
    struct GDTFSource: Equatable, Sendable {
        let rid: Int
        let manufacturer: String
        let fixture: String
        let revision: String
        /// "Manuf." for the manufacturer's own upload, "User" otherwise.
        let uploader: String
        let modified: Date

        var isFromManufacturer: Bool { uploader.lowercased().hasPrefix("manuf") }
    }

    /// Keyed by the GDTF's file name, as fixtures' `<GDTFSpec>` names it.
    static func gdtfSources(in document: XMLDocument) -> [String: GDTFSource] {
        guard let data = dataElement(in: document, creating: false) else { return [:] }
        var sources: [String: GDTFSource] = [:]
        for entry in data.elements(forName: "GDTFSource") {
            func value(_ name: String) -> String { entry.attribute(forName: name)?.stringValue ?? "" }
            guard !value("file").isEmpty, let rid = Int(value("rid")) else { continue }
            sources[value("file")] = GDTFSource(
                rid: rid, manufacturer: value("manufacturer"), fixture: value("fixture"),
                revision: value("revision"), uploader: value("uploader"),
                modified: Date(timeIntervalSince1970: Double(value("modified")) ?? 0))
        }
        return sources
    }

    // MARK: - Session

    /// The Auto ID session, as one JSON blob in a `<Session>` element.
    ///
    /// JSON rather than a tree of elements: this is our own private data
    /// that nothing else parses, it changes shape every time a correction
    /// is added, and a schema no other tool reads is a schema not worth
    /// hand-rolling. `<Group>` above stays as it is — a plain per-fixture
    /// name that survives even when a group's membership no longer does.
    static func session(in document: XMLDocument) -> AutoIDStoredSession? {
        guard let data = dataElement(in: document, creating: false),
              let element = data.elements(forName: "Session").first,
              let text = element.stringValue else { return nil }
        return AutoIDStoredSession.decoded(from: text)
    }

    // MARK: - Elements

    private static func dataElement(in document: XMLDocument, creating: Bool) -> XMLElement? {
        guard let root = document.rootElement(),
              let userData = userDataElement(in: root, creating: creating) else { return nil }
        return userData.elements(forName: "Data").first {
            $0.attribute(forName: "provider")?.stringValue == provider
        }
    }

    private static func userDataElement(in root: XMLElement, creating: Bool) -> XMLElement? {
        if let existing = root.elements(forName: "UserData").first { return existing }
        guard creating else { return nil }

        // First child, which is where the files in the wild carry it —
        // ahead of <Scene>.
        let created = XMLElement(name: "UserData")
        root.insertChild(created, at: 0)
        return created
    }
}
